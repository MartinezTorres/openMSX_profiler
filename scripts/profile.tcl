#
# Profiling utility
#
# With this utility you can profile the time spent in sections of your code.
# To measure a section you need to instrument it with TCL script breakpoints
# to indicate the start and end, and what section it belongs to.
#
# Additionally you can divide the measurements in frame blocks by using the
# “frame” section. This section is treated as a frame delimiter, and every time
# this section starts all the section times are reset and the OSD is updated.
#
# It is also possible to exclude the time spent in one section from another.
# Useful for interrupt handlers and synchronisation wait loops.
#
# Commands:
#
# profile [<ids>] [<unit>]
# profile_osd [<unit>]
# profile_restart
# profile_break <ids>
# profile::section_begin <ids>
# profile::section_end <ids>
# profile::section_begin_bp <ids> <address> [<condition>]
# profile::section_end_bp <ids> <address> [<condition>]
# profile::section_scope_bp <ids> <address> [<condition>]
# profile::section_irq_bp <ids> [<condition>]
# profile::section_create <ids>
# profile::section_exclude <exclude_ids> <ids>
# profile::section_list [<filter_ids>]
# profile::section_with <ids> <body>
#
# See help <command> for more information.
#

namespace eval profile {
	variable sections [dict create]
    
	variable frame_start_time 0
	variable frame_total_time 0
    
    
    variable is_init 0
    proc init {} {
        
        variable is_init
        
        variable frame_total_time
        set frame_total_time [expr {(1368.0 * (([vdpreg 9] & 2) ? 313 : 262)) / (6 * 3579545)}]
                
        if {$is_init} { return }
        set is_init 1
        
        section_init_frame_and_irq        
        section_vdp_bp "vdp"
    }
    
#
# OSD Interface
#    
	variable width 150
	variable height 5
    variable avg_ratio 0.05
    
    variable osd_units { % s ms t lines }
	variable osd_unit_index 0
	variable osd_unit %

    variable last_event_time 0
    variable osd_last_updated 0
    
#
# VDP Helper Functions:
#
	set_help_text profile::get_VDP_frame_duration [join {
		"Usage: profile::get_VDP_frame_duration\n"
		"Returns the duration, in seconds, of the VDP frame."
	} {}]
    proc get_VDP_frame_duration {} {
        expr {(1368.0 * (([vdpreg 9] & 2) ? 313 : 262)) / (6 * 3579545)}
    }

	set_help_text profile::get_start_of_VDP_frame_time [join {
		"Usage: profile::get_start_of_VDP_frame_time\n"
		"Returns the time, in seconds, of the start of the VDP last frame."
	} {}]
    proc get_start_of_VDP_frame_time {} {
        expr {[machine_info time] - [machine_info VDP_cycle_in_frame] / (6.0 * 3579545)}
    }
    
	set_help_text profile::get_time_since_VDP_start [join {
		"Usage: profile::get_time_since_VDP_start\n"
		"Returns the time that has passed, in seconds, since the start of the last VDP start."
	} {}]
    proc get_time_since_VDP_start {} {
        expr {[machine_info VDP_cycle_in_frame] / (6.0 * 3579545)}
    }   

# 
# Z80 interface:
#

    variable z80_interface_enabled 0
    variable z80_self_estimation_time_unit [expr 1 / 6000]
    variable z80_self_estimation_time 0
    variable z80_section_name_address 0xF931

	set_help_text profile::get_debug_string [join {
		"Usage: profile::get_debug_string <address>\n"
		"Reads a null terminated string from the stated address."
	} {}]
    proc get_debug_string {address} {
        set s ""; 
        while {[peek $address] != 0 && [string length $s] < 255} { 
            append s [format %c [peek $address]];  
            incr address 1;  
        }; 
        expr {$s}
    }
    
	set_help_text profile::enable_z80_interface [join {
		"Usage: profile::start_z80_interface \[<begin_port>] \[<end_port>] \[<section_name_address>]\n"
		"Enables the z80 interface."
        "To start a section, write the pointer to the section name to address <section_name_address>, and then send any byte to the I/O port <begin_port>."
        "To end a section, write the pointer to the section name to address <section_name_address>, and then send any byte to the I/O port <end_port>."
        "Enabling the z80 interface automatically enables the IRQ section, that tracks the time spent in the IRQ, and the FRAME section which tracks the time between IRQs."
	} {}]
    proc enable_z80_interface { {begin_port {0x2C}} {end_port {0x2D}} {section_name_address {0xF931}}} {
        
        variable z80_interface_enabled
        if {$z80_interface_enabled} {return}
        set z80_interface_enabled 1
        
        set z80_section_name_address $section_name_address
        
        debug set_watchpoint write_io $begin_port {} [namespace code {
            set name [get_debug_string [peek16 $z80_section_name_address]]
            if {[string match "exec:*" $name]} {
                [string range $name 5 end]
            } else {
                set z80_self_estimation_time $::wp_last_value
                section_begin $name
                set z80_self_estimation_time 0
            }
        }]

        debug set_watchpoint write_io $end_port {} [namespace code {
            set name [get_debug_string [peek16 $z80_section_name_address]]
            if {[string match "exec:*" $name]} {
                [string range $name 5 end]
            } else {
                set z80_self_estimation_time $::wp_last_value
                section_end $name
                set z80_self_estimation_time 0
            }
        }]
    }

	set_help_text profile::enable_z80_self_estimation [join {
		"Usage: profile::enable_z80_self_estimation \[<begin_port>] \[<end_port>] \[<section_name_address>] \[<time_unit>]\n"
		"Enables the z80 self estimaton feature."
        "This code is useful when we design z80 code that keeps track of the time that has passed since the VDP interruption started."
        "In this case, you must write the time that has passed to the I/O ports when starting or ending a section."
        "The default unit is 1/6000 of a second, i.e., 1 percent of the frame time at 60 Hz, but it can be set to any value."
	} {}]
    proc enable_z80_self_estimation { {time_unit {[expr 1 / 6000]}} } {
        
        variable z80_self_estimation_time_unit
        set z80_self_estimation_time_unit $time_unit
    }

# 
# IRQ interface:
#

	variable irq_status 0
    
	proc section_init_frame_and_irq {} {
        
		section_create "frame"
		section_create "irq"
        
		set begin [namespace code "variable \$irq_status; incr \$irq_status;  section_end frame; section_begin frame; section_begin irq"]
		set end [namespace code "section_end irq; variable irq_status; if {\$irq_status>0} { incr \$irq_status -1 }"]
		set handler "$begin\ndebug set_watchpoint read_mem -once \[expr {\[reg sp] - 2}] {} {debug set_condition -once {} {$end}}"
		debug probe set_bp z80.acceptIRQ {} $handler
		if {{r800.acceptIRQ} in [debug probe list]} {
			debug probe set_bp r800.acceptIRQ {} $handler
		}
	}
    
	set_help_text profile::section_irq_bp [join {
		"Usage: profile::section_irq_bp <ids> \[<condition>]\n"
		"Define a probe breakpoint which starts a section when the CPU accepts "
		"an IRQ, and ends it after the return address on the stack is read, "
		"typically when it returns. Useful for profiling interrupt handlers."
	} {}]
	proc section_irq_bp {ids {condition {}}} {
		section_create $ids
		set begin [namespace code "variable \$irq_status; incr \$irq_status; section_begin {$ids}"]
		set end [namespace code "section_end {$ids}; variable irq_status; if {\$irq_status>0} { incr \$irq_status -1 }"]
		set handler "$begin\ndebug set_watchpoint read_mem -once \[expr {\[reg sp] - 2}] {} {debug set_condition -once {} {$end}}"
		debug probe set_bp z80.acceptIRQ $condition $handler
		if {{r800.acceptIRQ} in [debug probe list]} {
			debug probe set_bp r800.acceptIRQ $condition $handler
		}
	}

# 
# VDP interface:
#

    set_help_text profile::section_vdp_bp [join {
		"Usage: profile::section_vdp_bp <ids> \[<condition>]\n"
		"Define a VDP command breakpoint which starts a section when a VDP "
		"command is executing and ends it when it completes."
	} {}]
	proc section_vdp_bp {ids {condition {}}} {
		section_create $ids
		if {[debug probe read VDP.commandExecuting]} {
			section_begin $ids
		}
		set begin [namespace code "section_begin {$ids}"]
		set end [namespace code "section_end {$ids}"]
		set handler "if {\[debug probe read VDP.commandExecuting\]} {$begin} else {$end}"
		debug probe set_bp VDP.commandExecuting $condition $handler
	}

# 
# Add monitored sections:
#

	set_help_text profile::section_begin_bp [join {
		"Usage: profile::section_begin_bp <ids> <address> \[<condition>]\n"
		"Define a breakpoint which starts a section."
	} {}]
	proc section_begin_bp {ids address {condition {}}} {
		section_create $ids
		debug set_bp $address $condition [namespace code "section_begin {$ids}"]
	}

	set_help_text profile::section_end_bp [join {
		"Usage: profile::section_end_bp <ids> <address> \[<condition>]\n"
		"Define a breakpoint which ends a section."
	} {}]
	proc section_end_bp {ids address {condition {}}} {
		section_create $ids
		debug set_bp $address $condition [namespace code "section_end {$ids}"]
	}

# 
# Add monitored function calls:
#

	set_help_text profile::section_scope_bp [join {
		"Usage: profile::section_scope_bp <ids> <address> \[<condition>]\n"
		"Define a breakpoint which starts a section, and will end it after the "
		"value on the top of the stack is read, typically when the method "
		"returns or when it is popped. Useful for profiling function calls."
	} {}]
	proc section_scope_bp {ids address {condition {}}} {
		section_create $ids
		set begin [namespace code "section_begin {$ids}"]
		set end [namespace code "section_end {$ids}"]
		debug set_bp $address $condition \
			"$begin\ndebug set_watchpoint read_mem -once \[reg sp] {} {debug set_condition -once {} {$end}}"
	}


# 
# Internal interface:
#

	set_help_text profile::section_create [join {
		"Usage: profile::section_create <ids>\n"
		"Predefines sections. Useful to specify the order they appear in."
	} {}]
	proc section_create {ids} {
        
        init
        
		variable sections
		foreach id $ids {
			if {![dict exists $sections $id]} {
				dict set sections $id [dict create \
					total_time 0 \
					sync_time 0 \
					count 0 \
					balance 0 \
					frame_time 0 \
					frame_time_base 0 \
					exclude_ids [list] \
					section_sync_time 0 \
					section_time 0 \
					section_time_avg 0 \
					section_time_max 0 \
					section_time_exp 0 \
                    start_time 0 \
                    osd_is_selected 0 \
                    osd_is_hidden 0 \
					break false \
				]
			}
		}
	}

	set_help_text profile::section_list [join {
		"Usage: profile::section_list \[<filter_ids>]\n"
		"Returns a list of all sections, optionally filtered."
	} {}]
	proc section_list {{filter_ids {}}} {
		variable sections
		set ids [dict keys $sections]
		foreach filter_id $filter_ids {
			set index [lsearch $ids $filter_id]
			set ids [lreplace $ids $index $index]
		}
		return $ids
	}

	set_help_text profile::section_with [join {
		"Usage: profile::section_with <ids> <body>\n"
		"Iterate over the specified sections, passed in scope of the body."
	} {}]
	proc section_with {ids body} {
		variable sections
		foreach id $ids {
			dict with sections $id {
				eval $body
			}
		}
	}

	set_help_text profile::section_begin [join {
		"Usage: profile::section_begin <ids>\n"
		"Starts a section. Use the “frame” ID to mark the beginning of a frame."
	} {}]
	proc section_begin {ids} {
        
		section_create $ids

        variable last_event_time
		set last_event_time [machine_info time]

        foreach id $ids {
            variable sections
            dict with sections $id { 
                variable irq_status
                set in_irq $irq_status

                incr balance

                if {$balance == 1} {
                    set start_time $last_event_time
                }                
                
                if {$break} {
                    set break false
                    debug break
                }
            }
        }
        
        osd_update
	}


	set_help_text profile::section_end [join {
		"Usage: profile::section_end <ids>\n"
		"Ends a section."
	} {}]
	proc section_end {ids} {
        
        variable last_event_time
        set last_event_time [machine_info time]

		foreach id $ids {
            variable sections
            dict with sections $id { 

                variable z80_self_estimation_time_unit
                variable z80_self_estimation_time
                
                variable frame_total_time

                if {$balance == 1} {
                    
                    variable avg_ratio
                    set section_time [expr {$last_event_time - $start_time}]
                    set section_time_max [expr {$section_time>$section_time_max?$section_time:$section_time_max}]
                    set section_time_avg [expr {$section_time_avg == 0 ? $section_time : $section_time_avg * (1-$avg_ratio) + $section_time * $avg_ratio}]
                    set section_time_exp [expr {$z80_self_estimation_time_unit != 0 ? 0.01 * $z80_self_estimation_time * $z80_self_estimation_time_unit : 0}]                    
                }

                if {$balance > 0} {
                    incr balance -1
                }
            }
		}
        
        
        osd_update
	}


# 
# OSD interface:
#

	proc osd_update {} {
        
        variable last_event_time
        variable osd_last_updated
        if {$last_event_time < $osd_last_updated + 0.01 } {
            return
        }
        
        set osd_last_updated $last_event_time

        
		if {![osd exists profile]} {
			return
		}
		section_with [section_list] {
			upvar index index
			variable frame_total_time

			set index [lsearch -exact [section_list] $id]

			if {![osd exists profile_main]} {
				variable width
				variable height
                
                set height20 [expr {2.0 * $height}]
                set height18 [expr {1.8 * $height}]
                set height01 [expr {0.1 * $height}]

                set widthButton [expr {3.8 * $height}]
				osd create rectangle profile_main -x 0 -y $height20 -w $width -h $height20 -scaled true -clip true -rgba 0x80000088
                
                osd create rectangle profile_main.restore -x [expr {0.1 * $height}] -y $height01 -w [expr {5.8 * $height}] -h $height18 -scaled true \
                    -bordersize $height01 -borderrgba 0x000000FF -rgba 0x008000FF
                osd create text      profile_main.restore.text -x [expr {4*$height / 6.}] -y [expr {2*$height / 6.}] -size [expr {2*$height * 3 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf" -text "Restore"

                osd create rectangle profile_main.hide -x [expr {6.1 * $height}] -y $height01 -w [expr {5.8 * $height}] -h $height18 -scaled true \
                    -bordersize $height01 -borderrgba 0x000000FF -rgba 0x008000FF
                osd create text      profile_main.hide.text -x [expr {4*$height / 6.}] -y [expr {2*$height / 6.}] -size [expr {2*$height * 3 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf" -text "Hide"

                osd create rectangle profile_main.sorting -x [expr {12.1 * $height}] -y $height01 -w [expr {5.8 * $height}] -h $height18 -scaled true \
                    -bordersize $height01 -borderrgba 0x000000FF -rgba 0x008000FF
                osd create text      profile_main.sorting.text -x [expr {4*$height / 6.}] -y [expr {2*$height / 6.}] -size [expr {2*$height * 3 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf" -text "Sorting"

                osd create rectangle profile_main.units -x [expr {18.1 * $height}] -y $height01 -w [expr {5.8 * $height}] -h $height18 -scaled true \
                    -bordersize $height01 -borderrgba 0x000000FF -rgba 0x008000FF
                osd create text      profile_main.units.text -x [expr {4*$height / 6.}] -y [expr {2*$height / 6.}] -size [expr {2*$height * 3 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf" -text "Units"

                osd create rectangle profile_main.reset -x [expr {24.1 * $height}] -y $height01 -w [expr {5.8 * $height}] -h $height18 -scaled true \
                    -bordersize $height01 -borderrgba 0x000000FF -rgba 0x008000FF
                osd create text      profile_main.reset.text -x [expr {4*$height / 6.}] -y [expr {2*$height / 6.}] -size [expr {2*$height * 3 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf" -text "Reset"
            }

			if {![osd exists profile_detail]} {
				variable width
				variable height
                
				osd create rectangle profile_detail -x 0 -y -$height -w $width -h $height20 -scaled true -clip true -rgba 0x80000088
                
            }
            
			if {![osd exists profile.$id]} {
				variable width
				variable height
				set y [expr {(4 + $index) * $height}]
				set rgba [osd_hya [expr {$index * 0.14}] 0.5 1.0]
				osd create rectangle profile.$id -x 0 -y $y -w $width -h $height -scaled true -clip true -rgba 0x00000088
				osd create rectangle profile.$id.bar -x 0 -y 0 -w 0 -h $height -scaled true -rgba $rgba
				osd create text profile.$id.remove -x [expr { 0*($height)}]  -y [expr { 0.25 * $height / 6.}] -size [expr {$height * 5 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf"
				osd create text profile.$id.break  -x [expr { 1*($height)}]  -y [expr { 0.25 * $height / 6.}] -size [expr {$height * 5 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf"
				osd create text profile.$id.select -x [expr { 2*($height)}]  -y [expr {-0.25 * $height / 6.}] -size [expr {$height * 5 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf"
				osd create text profile.$id.avg    -x [expr { 3*($height)}]  -y [expr { 0.5  * $height / 6.}] -size [expr {$height * 4 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSansMono.ttf"
				osd create text profile.$id.max    -x [expr { 8*($height)}]  -y [expr { 0.5  * $height / 6.}] -size [expr {$height * 4 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSansMono.ttf"
				osd create text profile.$id.name   -x [expr {13*($height)}] -y [expr { 0.5  * $height / 6.}] -size [expr {$height * 4 / 6}] -scaled true -rgba 0xffffffff -font "skins/DejaVuSans.ttf"

                osd configure profile.$id.remove -text "\u2718"
			}

			set fraction [expr {$frame_total_time != 0 ? $section_time_avg / $frame_total_time : 0}]
			set fraction_clamped [expr {$fraction < 0 ? 0 : $fraction > 1 ? 1 : $fraction}]
			osd configure profile.$id.bar -w [expr {$fraction_clamped * [osd info profile.$id -w]}]


            osd configure profile.$id.break -text [expr {$break?"\u2611":"\u2610"}]
            osd configure profile.$id.select -text [expr {$index==0?"\u25C9":"\u25CE"}]
			osd configure profile.$id.avg -text [format "avg:%s" [to_unit $section_time_avg]]
			osd configure profile.$id.max -text [format "max:%s" [to_unit $section_time_max]]
			osd configure profile.$id.name -text $id
		}
	}

	proc osd_hya {h y a} {
		set h [expr {($h - floor($h)) * 8.0}]
		osd_yuva $y [expr {$h < 2.0 ? -1.0 : $h < 4.0 ? $h - 3.0 : $h < 6.0 ? 1.0 : 7.0 - $h}] \
		            [expr {$h < 2.0 ? $h - 1.0 : $h < 4.0 ? 1.0 : $h < 6.0 ? 5.0 - $h : -1.0}] $a
	}

	proc osd_yuva {y u v a} {
		set r [fraction_to_uint8 [expr {$y + 1.28033 * 0.615 * $v}]]
		set g [fraction_to_uint8 [expr {$y - 0.21482 * 0.436 * $u - 0.38059 * 0.615 * $v}]]
		set b [fraction_to_uint8 [expr {$y + 2.12798 * 0.436 * $u}]]
		set a [fraction_to_uint8 $a]
		expr {$r << 24 | $g << 16 | $b << 8 | $a}
	}

	proc fraction_to_uint8 {value} {
		set value [expr {round($value * 255)}]
		expr {$value > 255 ? 255 : $value < 0 ? 0 : $value}
	}


    proc to_unit {seconds} {
        variable osd_unit
        variable frame_total_time
        if {$osd_unit eq "s"} {
            return [format "%5.3f s" [expr {$seconds}]]
        } elseif {$osd_unit eq "ms"} {
            return [format "%5.2f ms" [expr {$seconds * 1000}]]
        } elseif {$osd_unit eq "t"} {
            set cpu [get_active_cpu]
            return [format "%5d T" [expr {round($seconds * [machine_info ${cpu}_freq])}]]
        } elseif {$osd_unit eq "lines"} {
            return [format "%5.1f lines" [expr {$seconds * 3579545 / 228}]]
        } else {
            return [format "%5.1f%%" [expr {$frame_total_time != 0 ? 100 * $seconds / $frame_total_time : 0}]]
        }
    }

	set_help_text profile [join {
		"Usage: profile \[<ids>] \[<unit>]\n"
		"Show the current profiling status in the console. "
		"Optionally specify section IDs and a unit (s, ms, t, %).\n"
		"\n"
		"Legend:\n"
		"- frame: the time spent in the last frame\n"
		"- current: shows the currently accumulated time\n"
		"- count: the number of times the section was started\n"
		"- balance: whether the CPU is currently in a section\n"
		"  If section starts and ends are imbalanced, balance will ever-increase.\n"
	} {}]
	proc profile {{ids {}} {unit "%"}} {
		if {$ids eq {}} {
			set ids [section_list]
		}
		section_with $ids {
			upvar unit unit
			variable frame_total_time

            if {$section_time_exp>0} {
                set text [format "%s exp:%s avg:%s max:%s" $id [to_unit $section_time_exp] [to_unit $section_time_avg] [to_unit $section_time_max]]
            } else {
                set text [format "%s avg:%s max:%s" $id [to_unit $section_time_avg] [to_unit $section_time_max]]
            }
		}
	}

	proc profile_tab {args} {
		if {[llength $args] == 2} { return [section_list] }
		if {[llength $args] == 3} { return [list s ms t lines %] }
	}

	set_tabcompletion_proc profile [namespace code profile_tab]

	set_help_text enable_osd [join {
		"Usage: enable_osd \[<unit>]\n"
		"Show the on-screen display of the current section frame times. "
		"The OSD updates at the beginning of each frame. "
		"Optionally specify the unit (s, ms, t or %)."
	} {}]
	proc enable_osd {{unit "%"}} {
		if {$unit ne ""} {
			variable osd_unit
			set osd_unit $unit
		}
		if {![osd exists profile]} {
			osd create rectangle profile
			after "mouse button1 down" [namespace code on_mouse_button1_down]
		} elseif {$unit eq ""} {
			osd destroy profile
		}
		return
	}
    
    
	set_help_text disable_osd [join {
		"Usage: disable_osd \[<unit>]\n"
		"Show the on-screen display of the current section frame times. "
		"The OSD updates at the beginning of each frame. "
		"Optionally specify the unit (s, ms, t, lines, or %)."
	} {}]
	proc disable_osd {{unit "%"}} {
		if {$unit ne ""} {
			variable osd_unit
			set osd_unit $unit
		}
			osd destroy profile
		return
	}

	set_help_text profile_restart [join {
		"Usage: profile_restart\n"
		"Restart the counters for average and max found values."
	} {}]
    proc profile_restart {} {
        section_with [section_list] {
            set section_sync_time 0
            set section_time 0
            set section_time_avg 0
            set section_time_max 0
            set section_time_exp 0
		}
    }

	proc profile_osd_tab {args} {
		if {[llength $args] == 2} { return [list s ms t lines %] }
	}

	set_tabcompletion_proc profile_osd [namespace code profile_osd_tab]

	set_help_text profile_break [join {
		"Usage: profile_break <ids>\n"
		"Breaks execution at the start of the section."
	} {}]
	proc profile_break {ids} {
		section_with $ids {
			set break true
			debug cont
		}
	}

	proc profile_break_tab {args} {
		if {[llength $args] == 2} { return [section_list] }
	}

	set_tabcompletion_proc profile_break [namespace code profile_break_tab]

	proc on_mouse_button1_down {} {

        if {[is_mouse_over profile_main.restore]} {
        }

        if {[is_mouse_over profile_main.hide]} {
        }

        if {[is_mouse_over profile_main.sorting]} {
        }
        
        if {[is_mouse_over profile_main.units]} {
            variable osd_units
            variable osd_unit_index
            variable osd_unit
            
            set osd_unit_index [expr { ($osd_unit_index + 1) % [llength $osd_units]}]
            set osd_unit [lindex $osd_units $osd_unit_index]
        }

        if {[is_mouse_over profile_main.reset]} {
        }

        
		if {[osd exists profile]} {
			profile_break [get_mouse_over_section]
			after "mouse button1 down" [namespace code on_mouse_button1_down]
		}
	}

	proc is_mouse_over {name} {
        if {[osd exists $name]} {
            lassign [osd info $name -mousecoord] x y
            if {$x >= 0 && $x <= 1 && $y >= 0 && $y <= 1} {
                return 1
            }
        }
        return 0
	}


	proc get_mouse_over_section {} {
		section_with [section_list] {
			if {[osd exists profile.$id]} {
				lassign [osd info profile.$id -mousecoord] x y
				if {$x >= 0 && $x <= 1 && $y >= 0 && $y <= 1} {
					return $id
				}
			}
		}
	}

	namespace export profile
	namespace export profile_osd
    namespace export profile_restart
	namespace export profile_break
}

namespace import profile::*
