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
# Z80 interface:
#
# Start a section by writing <id> to I/O port 2Ch on the Z80.
# End a section by writing <id> to I/O port 2Dh on the Z80.
# Since only numeric IDs can be used, use 255 to indicate the “frame” ID.
#

namespace eval profile {
	variable sections [dict create]
	variable frame_start_time 0
	variable frame_total_time 0
	variable width 120
	variable height 6
	variable osd_unit %
    
    proc getDebugString {} {set a [peek16 0xF931 ]; set b ""; while {[peek $a] > 0} { append b [format %c [peek $a]];  incr a 1;  }; expr {$b}}
    
    debug set_watchpoint write_io 0x2C {} [namespace code {
		section_begin [getDebugString]
	}]

	debug set_watchpoint write_io 0x2D {} [namespace code {
		section_end [getDebugString] $::wp_last_value
	}]
        
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

	set_help_text profile::section_irq_bp [join {
		"Usage: profile::section_irq_bp <ids> \[<condition>]\n"
		"Define a probe breakpoint which starts a section when the CPU accepts "
		"an IRQ, and ends it after the return address on the stack is read, "
		"typically when it returns. Useful for profiling interrupt handlers."
	} {}]
	proc section_irq_bp {ids {condition {}}} {
		section_create $ids
		set begin [namespace code "section_begin {$ids}"]
		set end [namespace code "section_end {$ids}"]
		set handler "$begin\ndebug set_watchpoint read_mem -once \[expr {\[reg sp] - 2}] {} {debug set_condition -once {} {$end}}"
		debug probe set_bp z80.acceptIRQ $condition $handler
		if {{r800.acceptIRQ} in [debug probe list]} {
			debug probe set_bp r800.acceptIRQ $condition $handler
		}
	}

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

	set_help_text profile::section_create [join {
		"Usage: profile::section_create <ids>\n"
		"Predefines sections. Useful to specify the order they appear in."
	} {}]
	proc section_create {ids} {
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
					break false \
				]
			}
		}
	}

	set_help_text profile::section_exclude [join {
		"Usage: profile::section_exclude <exclude_ids> <ids>\n"
		"Excludes measuring time from one section in another."
	} {}]
	proc section_exclude {exclude_ids ids} {
		set dependencies [section_dependencies $exclude_ids]
		foreach id $ids {
			if {$id in $dependencies} {
				error "Excluding $exclude_ids from $id introduces a cycle."
			}
		}
		foreach exclude_id $exclude_ids {
			section_with $ids {
				upvar exclude_id exclude_id
				lappend exclude_ids $exclude_id
			}
		}
	}

	proc section_dependencies {ids} {
		section_with $ids {
			upvar ids ids_
			lappend ids_ {*}[section_dependencies $exclude_ids]
		}
		return $ids
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
		section_create $ids
		set machine_time [machine_info time]
		foreach id $ids {
			dict with sections $id {
				set time $machine_time
				section_with $exclude_ids {
					upvar time time_
					set time_ [expr {$time_ - $total_time}]
				}
				if {$balance > 0} {
					set total_time [expr {$total_time + $time - $sync_time}]
				}
				set sync_time $time
				eval $body
			}
		}
	}

	set_help_text profile::section_begin [join {
		"Usage: profile::section_begin <ids>\n"
		"Starts a section. Use the “frame” ID to mark the beginning of a frame."
	} {}]
	proc section_begin {ids} {
		section_with $ids {
			incr balance
			incr count
            set section_sync_time $sync_time
			if {$break} {
				set break false
				debug break
			}
		}
		if {"frame" in $ids} {
			section_frame_flush
		}
	}

	set_help_text profile::section_end [join {
		"Usage: profile::section_end <ids>\n"
		"Ends a section."
	} {}]
	proc section_end {{ids {}} {expected_ratio {0}}} {
		section_with $ids {
            upvar expected_ratio expected_ratio
            variable frame_total_time

            if {$balance == 1} {
                set section_time [expr {$sync_time - $section_sync_time}]
                set section_time_max [expr {$section_time>$section_time_max?$section_time:$section_time_max}]
                set section_time_avg [expr {$section_time_avg == 0 ? $section_time : $section_time_avg * 0.99 + $section_time * 0.01}]
                set section_time_exp [expr {$frame_total_time != 0 ? 0.01 * $expected_ratio * $frame_total_time : 0}]
            }

			incr balance -1
		}
	}

	proc section_frame_flush {} {
		variable frame_start_time
		variable frame_total_time
		set time [machine_info time]
		set frame_total_time [expr {$frame_total_time==0 && $frame_start_time !=0 ? $time - $frame_start_time : $frame_total_time}]
		set frame_start_time $time
		section_with [section_list] {
			set frame_time [expr {$total_time - $frame_time_base}]
			set frame_time_base $total_time
		}
		osd_update
	}

	proc osd_update {} {
		if {![osd exists profile]} {
			return
		}
		section_with [section_list] {
			upvar index index
			variable frame_total_time
			variable osd_unit

			if {![osd exists profile.$id]} {
				variable width
				variable height
				set index [lsearch -exact [section_list] $id]
				set x [expr {($index * $height / 240) * $width}]
				set y [expr {$index * $height % 240}]
				set rgba [osd_hya [expr {$index * 0.14}] 0.5 1.0]
				osd create rectangle profile.$id -x $x -y $y -w $width -h $height -scaled true -clip true -rgba 0x00000088
				osd create rectangle profile.$id.bar -x 0 -y 0 -w 0 -h $height -scaled true -rgba $rgba
				osd create text profile.$id.text -x 2 -y 1 -size [expr {$height - 3}] -scaled true -rgba 0xffffffff
			}

			set fraction_exp [expr {$frame_total_time != 0 ? $section_time_exp / $frame_total_time : 0}]
			
			set fraction_max [expr {$frame_total_time != 0 ? $section_time_max / $frame_total_time : 0}]
			set fraction_max_clamped [expr {$fraction_max < 0 ? 0 : $fraction_max > 1 ? 1 : $fraction_max}]

			set fraction [expr {$frame_total_time != 0 ? $section_time_avg / $frame_total_time : 0}]
			set fraction_clamped [expr {$fraction < 0 ? 0 : $fraction > 1 ? 1 : $fraction}]
			osd configure profile.$id.bar -w [expr {$fraction_clamped * [osd info profile.$id -w]}]

			if {$osd_unit eq "s"} {
				set text [format "%s avg:%.3f s max:%.3f s" $id $frame_time_avg $frame_time_max]
			} elseif {$osd_unit eq "ms"} {
				set text [format "%s avg:%.2f ms max:%.2f ms" $id [to_ms $frame_time_avg $frame_time_max]]
			} elseif {$osd_unit eq "t"} {
				set text [format "%s avg:%d T max:%d T" $id [to_cycles $frame_time_avg $frame_time_max]]
			} elseif {$osd_unit eq "lines"} {
				set text [format "%s avg:%.0f lines max:%.0f lines" $id [to_lines $frame_time_avg $frame_time_max]]
			} else {
                if {$fraction_exp>0} {
                    set text [format "%s exp:%00.0f%% avg:%00.1f%% max:%00.1f%%" $id [expr {$fraction_exp * 100}] [expr {$fraction * 100}] [expr {$fraction_max * 100}]] 
                } {
                    set text [format "%s avg:%00.1f%% max:%00.1f%%" $id [expr {$fraction * 100}] [expr {$fraction_max * 100}]] 
                }
			}
			osd configure profile.$id.text -text $text
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

	proc to_ms {seconds} {
		expr {$seconds * 1000}
	}

	proc to_lines {seconds} {
		expr {$seconds * 15720}
	}

	proc to_cycles {seconds} {
		set cpu [get_active_cpu]
		expr {round($seconds * [machine_info ${cpu}_freq])}
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
	proc profile {{ids {}} {unit "lines"}} {
		if {$ids eq {}} {
			set ids [section_list]
		}
		section_with $ids {
			upvar unit unit
			variable frame_total_time
			set percentage [expr {$frame_total_time != 0 ? $frame_time * 100 / $frame_total_time : 0}]
			set current [expr {$total_time - $frame_time_base}]
            set current_avg [expr { ( $total_time - $frame_time_base) / ($count+0.0001) }]

			if {$unit eq "s"} {
				set frame_unit [format {%.8f s} $frame_time]
				set current_unit [format {%.8f s} $current]
				set current_avg_unit [format {%.8f s} $current_avg ]
			} elseif {$unit eq "ms"} {
				set frame_unit [format {%.5f ms} [to_ms $frame_time]]
				set current_unit [format {%.5f ms} [to_ms $current]]
				set current_avg_unit [format {%.5f ms} [to_ms $current_avg]]
			} elseif {$unit eq "t"} {
				set frame_unit [format {%d T} [to_cycles $frame_time]]
				set current_unit [format {%d T} [to_cycles $current]]
				set current_avg_unit [format {%d T} [to_cycles $current_avg]]
			} elseif {$unit eq "lines"} {
				set frame_unit [format {%.5f lines} [to_lines $frame_time]]
				set current_unit [format {%.5f lines} [to_lines $current]]
				set current_avg_unit [format {%.5f lines} [to_lines $current_avg]]
			} else {
				set frame_unit [format {%05.2f%%} $percentage]
				set current_unit [format {%.8f s} $current]
				set current_avg_unit [format {%.8f s} $current_avg ]
			}

			if {$frame_total_time != 0} {
				puts [format {%s :: frame: %s, current: %s, count: %d, balance: %d} \
					$id $frame_unit $current_unit $count $balance]
			} else {
				puts [format {%s :: current: %s, count: %d, balance: %d, avg: %s} \
					$id $current_unit $count $balance $current_avg_unit]
			}
		}
	}

	proc profile_tab {args} {
		if {[llength $args] == 2} { return [section_list] }
		if {[llength $args] == 3} { return [list s ms t %] }
	}

	set_tabcompletion_proc profile [namespace code profile_tab]

	set_help_text profile_osd [join {
		"Usage: profile_osd \[<unit>]\n"
		"Show the on-screen display of the current section frame times. "
		"The OSD updates at the beginning of each frame. "
		"Optionally specify the unit (s, ms, t or %)."
	} {}]
	proc profile_osd {{unit "lines"}} {
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
		if {[llength $args] == 2} { return [list s ms t %] }
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
		if {[osd exists profile]} {
			profile_break [get_mouse_over_section]
			after "mouse button1 down" [namespace code on_mouse_button1_down]
		}
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
