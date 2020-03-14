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
    
    variable last_event_time 0

    variable avg_ratio 0.05
    
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
        return $s
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
                eval [string range $name 5 end]
            } else {
                set z80_self_estimation_time $::wp_last_value
                section_begin [string map {" " "_"} $name]
                set z80_self_estimation_time 0
            }
        }]

        debug set_watchpoint write_io $end_port {} [namespace code {
            set name [get_debug_string [peek16 $z80_section_name_address]]
            if {[string match "exec:*" $name]} {
                eval [string range $name 5 end]
            } else {
                set z80_self_estimation_time $::wp_last_value
                section_end [string map {" " "_"} $name]
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
        
        
        gui_update
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
        
        
        
        gui_update
	}


# 
# GUI interface:
#
    variable gui_last_updated 0
#    variable osd_units { % s ms t lines }
#	variable osd_unit_index 0
#	variable osd_unit %

    variable gui_config [dict create \
        width 150 \
        height 6 \
        font_mono "skins/DejaVuSansMono.ttf" \
        font_sans "skins/DejaVuSans.ttf" \
        unit % \
        current_help_widget "" \
        num_sections 0 \
        num_favorite_sections 0 \
        selected_section "" \
        favorite_sections [dict create] \
        section_color [dict create] \
        next_color 0 \
        sorting_criteria "avg" \
        profile.all.ordering [dict create] \
        profile.favorite.ordering [dict create] \
        ] 
 
    variable gui_buttons [dict create]
    
    proc gui_add_button {widget on_press on_release on_activation upkeep help} {
        
        variable gui_buttons
        dict set gui_buttons $widget [ dict create \
            activated 0 \
            on_press $on_press \
            on_release $on_release \
            on_activation $on_activation \
            upkeep $upkeep \
            help $help]
    }
            

	proc gui_on_mouse_button1_down {} {
        
        variable gui_buttons
        dict for {widget button} $gui_buttons {
            if {[gui_is_mouse_over $widget]} {
                dict set gui_buttons $widget activated 1
                eval [dict get $gui_buttons $widget on_press]
            }
        }
        after "mouse button1 up"   [namespace code gui_on_mouse_button1_up]
	}
    
	proc gui_on_mouse_button1_up {} {
        
        variable gui_buttons
        dict for {widget button} $gui_buttons {

            if {[gui_is_mouse_over $widget] && [dict get $gui_buttons $widget activated]} {
                eval [dict get $gui_buttons $widget on_activation]
            }
            dict set gui_buttons $widget activated  0
            eval [dict get $gui_buttons $widget on_release]
        }
        after "mouse button1 down" [namespace code gui_on_mouse_button1_down]
	}
    
    proc gui_on_mouse_motion {} {
        
        variable gui_config
        variable gui_buttons
        
        #if {![gui_is_mouse_over [dict get $gui_config current_help_widget]]} {
        
            dict for {widget button} $gui_buttons {
                if {[gui_is_mouse_over $widget]} {
                    
                    osd configure profile.config.info.text -text [dict get $gui_buttons $widget help]
                    dict set gui_config current_help_widget $widget
                }
            }
        #}
        after "mouse motion" [namespace code gui_on_mouse_motion]
	}
    
	proc gui_is_mouse_over {widget} {
        if {[osd exists $widget]} {
            lassign [osd info $widget -mousecoord] x y
            if {$x >= 0 && $x <= 1 && $y >= 0 && $y <= 1} {
                return 1
            }
        }
        return 0
	}

    proc gui_create {} {
        

        variable gui_config
        variable gui_buttons
        
        set w [dict get $gui_config width]
        set h [dict get $gui_config height]
        
        #
        # Helper Subfunctions
        #

        # Scroll Buttons
        proc add_scroll_button {parent icon1 icon2 upkeep1 upkeep2} {

            variable gui_config
            variable gui_buttons
            
            set w [dict get $gui_config width]
            set h [dict get $gui_config height]
            
            osd create rectangle $parent.scroll -relx 1.0 -w [expr -1*$h] -h $h -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF
            osd create text      $parent.scroll.text -x [expr 1.5*$h/6.-$h] -y [expr -0.25*$h/6.] -size [expr 5*$h/6] -rgba 0x000000FF \
                -font [dict get $gui_config font_mono] -text $icon2

            gui_add_button $parent.scroll \
                "eval { osd configure $parent.scroll -rgba 0xC0C0C0FF } " \
                "eval { osd configure $parent.scroll -rgba 0x808080FF } " \
                "eval {
                    if { \[osd info $parent.scroll.text -text] == \"$icon1\" } {
                        osd configure $parent.scroll.text -text \"$icon2\"
                    } else {
                        osd configure $parent.scroll.text -text \"$icon1\"
                    }
                }" \
                "eval {
                    set parent $parent
                    variable gui_config
                    if { \[osd info $parent.scroll.text -text] == \"$icon1\" } {
                        $upkeep1
                    } else {
                        $upkeep2
                    }
                }" \
                "$parent Scroll Button"
        }
        
        # Config Buttons
        proc add_config_button {name x y text on_pressed help} {
            
            variable gui_config
            variable gui_buttons
            
            set w [dict get $gui_config width]
            set h [dict get $gui_config height]
            
            osd create rectangle profile.config.$name  -x [expr $x*$w/4.] -y [expr ($y+1)*$h] -w [expr $w/4-0.1*$h] -h [expr 0.9*$h] -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF
            osd create text      profile.config.$name.text -x [expr 1.5*$h/6.] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xFFFFFFFF \
                -font [dict get $gui_config font_sans] -text [eval $text]

            gui_add_button profile.config.$name \
                "eval { osd configure profile.config.$name -rgba 0xC0C0C0FF } " \
                "eval { osd configure profile.config.$name -rgba 0x808080FF } " \
                "eval { $on_pressed }" \
                "" \
                "$help"
        }
        
        #
        # Main Profiler Window
        #
        osd create rectangle profile -x 0 -y 20 -w $w -relh 1 -scaled true -clip true -rgba 0x00000000
        after "mouse button1 down" [namespace code gui_on_mouse_button1_down]


        add_scroll_button profile "\u25BA" "\u25C4" {
            set w [dict get $gui_config width]
            set h [dict get $gui_config height]
            osd configure profile -x [expr {[osd info profile -x] * 0.8 + (-$w+$h)*0.2}] 
        } { 
            osd configure profile -x [expr {[osd info profile -x] * 0.8 + 0 * 0.2}] 
        }
            
        #
        # Section: Configuration
        osd create rectangle profile.config -y $h -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
        osd create text      profile.config.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $gui_config font_sans] \
            -text "Configuration"

        add_scroll_button profile.config "\u25BC" "\u25B2" {
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*[dict get $gui_config height]}]
        } { 
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*5*[dict get $gui_config height]}]
        }
            
        
        add_config_button sort  0 0 {format "Sort:"} {} "Sort"
        add_config_button unit  1 0 {format "Unit:"} {} "Unit"
        add_config_button z80i  2 0 {format "Z80i:"} {} "z80i"
        add_config_button file  3 0 {format "File:"} {} "File"
        add_config_button pause 0 1 {format "Pause:"} {} "Pause"
        add_config_button clear 1 1 {format "Clear:"} {} "Clear"
        add_config_button avg   2 1 {format "Avg:"} {} "Avg"
        add_config_button hsize   3 1 {format "H Size: %d" [dict get $gui_config height]} {
            variable gui_config
            dict set gui_config height [expr 5+([dict get $gui_config height]+1-5)%3]
            osd destroy profile
            gui_create
        } "Toggles text Size between 5, 6, and 7"

        osd create rectangle profile.config.info  -x [expr 0*$w/4.] -y [expr (2+1)*$h] -w [expr $w-0.1*$h] -h [expr 1.9*$h] -rgba 0x40404080
        osd create text      profile.config.info.text -x [expr 1.5*$h/6.] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xC0C0C0FF \
                -font [dict get $gui_config font_sans] -text "Command Info"

        after "mouse motion" [namespace code gui_on_mouse_motion]

        
        #
        # Section: All
        osd create rectangle profile.all -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
        osd create text      profile.all.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $gui_config font_sans] \
            -text "All"

        add_scroll_button profile.all "\u25BC" "\u25B2" {
            osd configure profile.all -y [expr {[osd info profile.config -y] + [osd info profile.config -h]}]                
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*[dict get $gui_config height]}]
        } { 
            osd configure profile.all -y [expr {[osd info profile.config -y] + [osd info profile.config -h]}]                
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*(1+[dict get $gui_config num_sections])*[dict get $gui_config height]}]
        }

        #
        # Section: Favorites
        osd create rectangle profile.favorite -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
        osd create text      profile.favorite.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $gui_config font_sans] \
            -text "Favorites"

        add_scroll_button profile.favorite "\u25BC" "\u25B2" {
            osd configure profile.favorite -y [expr {[osd info profile.all -y] + [osd info profile.all -h]}]                
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*[dict get $gui_config height]}]
        } { 
            osd configure profile.favorite -y [expr {[osd info profile.all -y] + [osd info profile.all -h]}]                
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*(1+[dict get $gui_config num_favorite_sections])*[dict get $gui_config height]}]
        }
        
        #
        # Section: Detailed Info
        osd create rectangle profile.detailed -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
        osd create text      profile.detailed.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $gui_config font_sans] \
            -text "Detailed"

        add_scroll_button profile.detailed "\u25BC" "\u25B2" {
            osd configure profile.detailed -y [expr {[osd info profile.favorite -y] + [osd info profile.favorite -h]}]                
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*[dict get $gui_config height]}]
        } { 
            osd configure profile.detailed -y [expr {[osd info profile.favorite -y] + [osd info profile.favorite -h]}]                
            osd configure $parent -h [expr {0.8*[osd info $parent -h]+0.2*5*[dict get $gui_config height]}]
        }
    }


    

	proc gui_add_info_bar {parent id} {
        
       	proc get_color {idx} {

            proc fraction_to_uint8 {value} {
                set value [expr {round($value * 255)}]
                expr {$value > 255 ? 255 : $value < 0 ? 0 : $value}
            }
            
            set h [expr $idx / 7.]
            set y [expr 0.33 + 0.33 * ($idx % 2) ]
            set a 1
        
            proc gui_yuva {y u v a} {
                
                
                set r [fraction_to_uint8 [expr {$y + 1.28033 * 0.615 * $v}]]
                set g [fraction_to_uint8 [expr {$y - 0.21482 * 0.436 * $u - 0.38059 * 0.615 * $v}]]
                set b [fraction_to_uint8 [expr {$y + 2.12798 * 0.436 * $u}]]
                set a [fraction_to_uint8 $a]
                expr {$r << 24 | $g << 16 | $b << 8 | $a}
            }        
            
            set h [expr {($h - floor($h)) * 8.0}]
            gui_yuva $y [expr {$h < 2.0 ? -1.0 : $h < 4.0 ? $h - 3.0 : $h < 6.0 ? 1.0 : 7.0 - $h}] \
                        [expr {$h < 2.0 ? $h - 1.0 : $h < 4.0 ? 1.0 : $h < 6.0 ? 5.0 - $h : -1.0}] $a
        }



        variable gui_config
        if {[dict exists $gui_config section_color $id]} {
            set color_idx [dict get $gui_config section_color $id]
        } else {
            set color_idx [dict get $gui_config next_color]
            dict incr gui_config next_color
            dict set gui_config section_color $id $color_idx
        }            
            
        set w [dict get $gui_config width]
        set w [dict get $gui_config width]
        set h [dict get $gui_config height]
        set fs [dict get $gui_config font_sans]
        set fm [dict get $gui_config font_mono]
        osd create rectangle $parent.$id -x 0 -y [expr -2*$h] -w $w -h $h -clip true -rgba 0x00000088
        osd create rectangle $parent.$id.bar -x 0 -y 0 -w 0 -h $h -rgba [get_color $color_idx]
                
        osd create rectangle $parent.$id.favorite -x [expr 0*$h] -h $h -w $h -rgba 0x00000000
        osd create text $parent.$id.favorite.text -x [expr 0.125*$h] -y [expr  0.125*$h/6.] -size [expr 5*$h/6] -rgba 0xffffffff -font $fs  -text "\u2606"
        gui_add_button $parent.$id.favorite \
            "eval { osd configure $parent.$id.favorite -rgba 0xFFFFFF40 } " \
            "eval { osd configure $parent.$id.favorite -rgba 0xFFFFFF00 } " \
            "variable gui_config
            if {\[dict exist \$gui_config favorite_sections $id]} {
                dict unset gui_config favorite_sections $id
            } else {
                dict set gui_config favorite_sections $id 1
            }" \
            "variable gui_config
            if {\[dict exist \$gui_config favorite_sections $id]} {
                osd configure $parent.$id.favorite.text -text \"\\u2605\"
            } else {
                osd configure $parent.$id.favorite.text -text \"\\u2606\"
            }
            set target \[expr \[dict get \$gui_config $parent.ordering $id]*\[dict get \$gui_config height]]
            osd configure $parent.$id -y \[expr {0.85*\[osd info $parent.$id -y]+0.15*\$target}]
            " \
            "Add/Remove $id to the favorites list" 


        osd create rectangle $parent.$id.select -x [expr 1*$h] -h $h -w $h -rgba 0x00000000
        osd create text $parent.$id.select.text -x [expr 0.125*$h] -y [expr -0.125*$h/6.] -size [expr 5*$h/6] -rgba 0xffffffff -font $fs  -text "\u25CE"
        gui_add_button $parent.$id.select \
            "osd configure $parent.$id.select -rgba 0xFFFFFF40 " \
            "osd configure $parent.$id.select -rgba 0xFFFFFF00 " \
            "eval { 
            variable gui_config
            dict set gui_config selected_section \"$id\" 
            } " \
            "eval { 
            variable gui_config                        
            if { \[dict get \$gui_config selected_section] == \"$id\" } {
                osd configure $parent.$id.select.text -text \"\\u25C9\"
            } else {
                osd configure $parent.$id.select.text -text \"\\u25CE\"
            } }" \
            "Select $id to be analized in detail" 

        osd create rectangle $parent.$id.avg -x [expr 2*$h] -h $h -w [expr 5*$h] -rgba 0x00000000
        osd create text $parent.$id.avg.text -x [expr 0.125*$h] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xffffffff -font $fm
        gui_add_button $parent.$id.avg "" "" "" \
            "variable sections
            set section_time_avg \[dict get \$sections $id section_time_avg]
            osd configure $parent.$id.avg.text -text \[format \"avg:%s\" \[gui_to_unit \$section_time_avg]]
            proc clamp01 {val} { set v \[expr \$val]; return \[expr \$v<0?0:\$v>1?1:\$v] }
            osd configure $parent.$id.bar -w \[expr \[osd info $parent.$id -w]*\[clamp01 \$section_time_avg/\[get_VDP_frame_duration]]] " \
            "Average duration of section: $id" 
        
        osd create rectangle $parent.$id.max -x [expr 7*$h] -h $h -w [expr 5*$h] -rgba 0x00000000
        osd create text $parent.$id.max.text -x [expr 0.125*$h] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xffffffff -font $fm
        gui_add_button $parent.$id.max \
            "osd configure $parent.$id.select -rgba 0xFFFFFF40 " \
            "osd configure $parent.$id.select -rgba 0xFFFFFF00 " \
            "variable sections \n dict set sections $id section_time_max 0" \
            "variable sections
            osd configure $parent.$id.max.text -text \[format \"max:%s\" \[gui_to_unit \[dict get \$sections $id section_time_max]]]" \
            "Maximum duration of section: $id
            Click to reset." 

        osd create text $parent.$id.name     -x [expr 12*$h] -y [expr   0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xffffffff -font $fs -text $id
                        
    }

	proc gui_update {} {
        
        # aim for a maximum update rate of 50Hz
        variable last_event_time
        variable gui_last_updated
        if {$last_event_time < $gui_last_updated + 0.02 } { return }
        set gui_last_updated $last_event_time

        # no need to update if there is no profile to update
		if {![osd exists profile]} { return }
        
        # perform upkeep actions (i.e., smooth transitions)
        variable gui_buttons
        dict for {widget button} $gui_buttons {
#            puts stderr [dict get $button upkeep] 
            eval [dict get $button upkeep] 
        }
        
        proc sort_sections {ids} {
        
            variable gui_config
            if {[dict get $gui_config sorting_criteria] == "avg"} {
                proc compare {a b} {
                    variable sections
                    set a0 [dict get $sections $a section_time_avg]
                    set b0 [dict get $sections $b section_time_avg]
                    if {$a0 > $b0} { return -1 } elseif {$a0 < $b0} { return 1 }
                    return [string compare $b $a]
                }
                set ids [lsort -command compare $ids]
            }
            return $ids
        }


        variable sections
        variable gui_config
        set idx 0
        foreach id [sort_sections [dict keys $sections]] {
            set idx [expr 1+$idx]
            dict set gui_config profile.all.ordering $id $idx
            dict set gui_config profile.favorite.ordering $id -5
            if {![osd exists profile.all.$id]} { 
                gui_add_info_bar profile.all $id
                gui_add_info_bar profile.favorite $id
            }
        }
        dict set gui_config num_sections $idx

        set idx 0
        foreach id [sort_sections [dict keys [dict get $gui_config favorite_sections]]] {
            set idx [expr 1+$idx]
            dict set gui_config profile.favorite.ordering $id $idx
        }
        dict set gui_config num_favorite_sections $idx        
        
	}


    proc gui_to_unit {seconds} {
        variable gui_config
        set unit [dict get $gui_config unit]

        if {$unit eq "s"} {
            return [format "%5.3f s" [expr {$seconds}]]
        } elseif {$unit eq "ms"} {
            return [format "%5.2f ms" [expr {$seconds * 1000}]]
        } elseif {$unit eq "t"} {
            set cpu [get_active_cpu]
            return [format "%5d T" [expr {round($seconds * [machine_info ${cpu}_freq])}]]
        } elseif {$unit eq "lines"} {
            return [format "%5.1f lines" [expr {$seconds * 3579545 / 228}]]
        } else {
            return [format "%5.1f%%" [expr 100 * $seconds / [get_VDP_frame_duration]]]
        }
    }


	set_help_text gui [join {
		"Usage: gui \[<enable>]\n"
	} {}]
	proc gui {{enable "toggle"}} {
        if {$enable=="toggle"} {
            set enable ![osd exists profile]
        }
		if {$enable && ![osd exists profile]} { gui_create }
		if {!$enable && [osd exists profile]} { osd destroy profile }
		return
	}

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



}

namespace import profile::*
