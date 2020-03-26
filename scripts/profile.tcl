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

    # Status: execution related temporal variables. 
    #    Resetting it shold not impact the gui.
    if ![info exists Status] { variable Status {} }
    variable Status_defaults [dict create \
        Tags [dict create] \
        auto_scan 0 \
        avg_halflife 1 \
        log_idx 0 \
        debug_cb [dict create] \
        debug_cb_idx 0 \
        active_tags [dict create] \
        z80_interface_enabled 0 \
        z80_section_name_address 0xF931 \
        ]
    
    # Tag: labeled portion of the code.
    variable Status_Tag_default [dict create \
            hash {} \
            debug_cb [dict create] \
            profile_level 0 \
            disabled 0 \
            alias "" \
            count 0 \
            depth 0 \
            previous_time_between_invocations 0 \
            previous_occupation 0 \
            previous_ts_begin 0 \
            previous_ts_end 0 \
            previous_duration 0 \
            previous_log [dict create] \
            current_log [dict create] \
            max_duration 0 \
            avg_duration 0 \
            max_time_between_invocations 0 \
            avg_time_between_invocations 0 \
            max_occupation 0 \
            avg_occupation 0 \
        ]
#
# Initialization:
#
    reset
    proc reset {} {
        deinit
        init
    }

    proc deinit {} {
        
        variable Status
        
        if {![dict exists $Status debug_cb]} return
        dict for {idx cb_id} [dict get $Status debug_cb] { remove_cb $cb_id }
        
        if {![dict exists $Status Tags]} return
        dict for {id val} [dict get $Status Tags] { tag_delete $id } 
        
        set Status [dict create]
    }

    proc get_function_hash {address} {
        
        append hash0 [debug read memory $address]
        incr address
        append hash1 [debug read memory $address]
        incr address
        append hash2 [debug read memory $address]
        return [format "%02X%02X%02X" $hash0 $hash1 $hash2]
    }
    
    proc disable id {
        
        variable Status
        dict set Status Tags $id disabled 1
        dict for {idx cb_id} [dict get $Status Tags $id debug_cb] { remove_cb $cb_id }
        dict set Status Tags $id debug_cb [dict create]
    }
    
    proc call_condition pc {
        
        set instr [debug read memory $pc]
        if {$instr == 0xCD} {return 1}
        set f [debug read "CPU regs" 1]
        # C4 CALL_NZ 
        if {$instr == 0xC4} {return [expr ($f & 0x40 == 0)] }
        # D4 CALL_NC 
        if {$instr == 0xD4} {return [expr ($f & 0x01 == 0)] }
        # E4 CALL_PO 
        if {$instr == 0xE4} {return [expr ($f & 0x04 == 0)] }
        # F4 CALL_P
        if {$instr == 0xF4} {return [expr ($f & 0x80 == 0)] }
        # CC CALL_Z
        if {$instr == 0xCC} {return [expr ($f & 0x40 != 0)] }
        # DC CALL_C
        if {$instr == 0xDC} {return [expr ($f & 0x01 != 0)] }
        # EC CALL_PE
        if {$instr == 0xEC} {return [expr ($f & 0x04 != 0)] }
        # FC CALL_M
        if {$instr == 0xFC} {return [expr ($f & 0x80 != 0)] }
        puts stderr [format "Unsupported call 0x%02X" $instr]
    }


    
    
    proc init {} {

        variable Status
        if {[dict size $Status]==0} {
            
            variable Status_defaults
            set Status $Status_defaults
            
            tag_create "irq"
            tag_add_cb "irq" set_bp 0x38 {} {
                profile::tag_begin "irq"
                profile::tag_add_cb_once "irq" set_watchpoint read_mem [reg sp] {} {
                    profile::tag_end "irq"
                }
            }
            
            tag_create "vdp"
            tag_add_cb "vdp" probe set_bp VDP.commandExecuting {} {
                if [debug probe read VDP.commandExecuting] {
                    profile::tag_begin "vdp"
                } else {
                    profile::tag_end "vdp"
                }
            }
            
            add_cb set_condition {[ \
                set pc [expr {256 * [debug read "CPU regs" 20] + [debug read "CPU regs" 21]}]; \
                set instr [debug read memory $pc]; \
                expr {($instr == 0xCD) || (($instr & 0xC7) == 0xC4) || (($instr & 0xC7) == 0xC7)} \
            ]} {
                
                if {![dict get $profile::Status auto_scan]} return

                set pc [expr {256 * [debug read "CPU regs" 20] + [debug read "CPU regs" 21]}]
                set instr [debug read memory $pc]
                if {$instr == 0xCD} {

                    set target_address [peek16 [expr {$pc+1}]]
                    set return_address [expr {$pc+3}]
                } elseif {($instr & 0xC7) == 0xC4} {
                    set f [debug read "CPU regs" 1]
                    # C4 CALL_NZ 
                    if       {$instr == 0xC4} { if {$f & 0x40 != 0} {return} 
                    # D4 CALL_NC 
                    } elseif {$instr == 0xD4} { if {$f & 0x01 != 0} {return} 
                    # E4 CALL_PO4
                    } elseif {$instr == 0xE4} { if {$f & 0x04 != 0} {return} 
                    # F4 CALL_P
                    } elseif {$instr == 0xF4} { if {$f & 0x80 != 0} {return} 
                    # CC CALL_Z
                    } elseif {$instr == 0xCC} { if {$f & 0x40 == 0} {return} 
                    # DC CALL_C
                    } elseif {$instr == 0xDC} { if {$f & 0x01 == 0} {return} 
                    # EC CALL_PE
                    } elseif {$instr == 0xEC} { if {$f & 0x04 == 0} {return} 
                    # FC CALL_M
                    } elseif {$instr == 0xFC} { if {$f & 0x80 == 0} {return} } 
                    set target_address [peek16 [expr {$pc+1}]]
                    set return_address [expr {$pc+3}]
                } else {
                    # RST
                    set target_address [expr {$instr - 0xC7}]
                    set return_address [expr {$pc+1}]
                }
                                
                #puts  -nonewline stderr "."
                
                set id [format "0x%04x_#%s" $target_address [profile::get_function_hash $target_address]]
                profile::tag_create $id
                
                if {[dict size [dict get $profile::Status Tags $id debug_cb]]>4} { 
                    puts stderr "Disabling $id"
                    profile::disable $id 
                
                }
                if [dict get $profile::Status Tags $id disabled] { return }
                
                profile::tag_begin $id
                profile::tag_add_cb_once $id set_bp $return_address  {} {
                    profile::tag_end $id
                }
            }
        }        
    }

#
# TAG creation and deletion:
#
    proc tag_create id {
        
        variable Status
        init
        
        if {![dict exists $Status Tags $id]} {
            variable Status_Tag_default
            dict set Status Tags $id $Status_Tag_default
        }
    }

    proc tag_delete id {
        
        variable Status
        
        if {![dict exists $Status Tags $id]} return
        dict for {idx cb_id} [dict get $Status Tags $id debug_cb] { remove_cb $cb_id }
        
        dict unset Status Tags $id
        dict unset Status active_tags $id
    }

#
# Debug Callbacks:
#

    proc remove_cb cb_id {
        
        lassign [split $cb_id #] type num
        switch $type {
            bp   { debug remove_bp $cb_id }
            wp   { debug remove_watchpoint $cb_id }
            cond { debug remove_condition $cb_id }
            pp   { debug probe remove_bp $cb_id }
            default { error [format "Unknown debug type: %s" $cb_id] }
        }
    }
    

    proc add_cb {args} {
        
        variable Status
        init
        
        set idx [dict get $Status debug_cb_idx]
        incr idx
        dict set Status debug_cb_idx $idx
                
        dict set Status debug_cb $idx [debug {*}$args ]
        return
    }
    
    proc add_cb_once {args} {
                
        variable Status
        init
        
        set idx [dict get $Status debug_cb_idx]
        incr idx
        dict set Status debug_cb_idx $idx
        
        set body [lindex $args end]
        set body "
            $body
            profile::remove_cb \[dict get \$profile::Status debug_cb $idx]
            dict unset profile::Status debug_cb $idx
        "
        set args [lreplace $args end end $body]
                
        dict set Status debug_cb $idx [debug {*}$args ]
        return
    }
    

    proc tag_add_cb {id args} {
        
        variable Status
        tag_create $id
        
        set idx [dict get $Status debug_cb_idx]
        incr idx
        dict set Status debug_cb_idx $idx
        
        set body [lindex $args end]
        set body "
            set id $id
            $body
        "
        set args [lreplace $args end end $body]
        
        dict set Status Tags $id debug_cb $idx [debug {*}$args ]

        return
    }

    proc tag_add_cb_once {id args} {
        
        variable Status
        tag_create $id
        
        set idx [dict get $Status debug_cb_idx]
        incr idx
        dict set Status debug_cb_idx $idx

        set body [lindex $args end]
        set body "set id \"$id\";
            $body
            if \[dict exists \$profile::Status Tags $id debug_cb $idx] {
                profile::remove_cb \[dict get \$profile::Status Tags $id debug_cb $idx]
                dict unset profile::Status Tags $id debug_cb $idx
            }
        "
        set args [lreplace $args end end $body]
        
        dict set Status Tags $id debug_cb $idx [debug {*}$args ]
        
        return
    }

# 
# Z80 interface:


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
# Add monitored sections:
#

	set_help_text profile::tag_begin_bp [join {
		"Usage: profile::tag_begin_bp <id> <address> \[<condition>]\n"
		"Define a breakpoint which starts a section."
	} {}]
	proc tag_begin_bp {id address {condition {}}} {
        tag_create $id [debug set_bp $address $condition [namespace code "tag_begin $id"]]
	}

	set_help_text profile::tag_end_bp [join {
		"Usage: profile::tag_end_bp <id> <address> \[<condition>]\n"
		"Define a breakpoint which ends a section."
	} {}]
	proc tag_end_bp {id address {condition {}}} {
        tag_create $id [debug set_bp $address $condition [namespace code "tag_end $id"]]
	}

# 
# Add monitored function calls:
#


	set_help_text profile::tag_scope_bp [join {
		"Usage: profile::tag_scope_bp <id> <address> \[<condition>]\n"
		"Define a breakpoint which starts a section, and will end it after the "
		"value on the top of the stack is read, typically when the method "
		"returns or when it is popped. Useful for profiling function calls."
	} {}]
	proc tag_scope_bp {id address {condition {}}} {

        tag_create $id
        dict set Status Tags $id hash [get_function_hash $address]
        tag_add_cb $id set_bp $address $condition {
            
            set hash [dict get $profile::Status Tags $id hash]
            if {$hash=={} || $hash==[profile::get_function_hash $address]} {
                profile::tag_begin $id
                profile::tag_add_cb_once $id set_watchpoint read_mem [reg sp] {} {profile::tag_end $id}
            }
        }
	}

# 
# Add all function calls:
# 


# 
# Internal interface:
#

	set_help_text profile::tag_begin [join {
		"Usage: profile::tag_begin <ids>\n"
	} {}]
	proc tag_begin id {
                
        variable Status
        
        # If the tag that wasn't active gets activated, we register the activation
        if {[dict get $Status Tags $id depth]==0} {

            # We add the tag to the list of active tags
            dict set Status active_tags $id [machine_info time]
            dict set Status Tags $id depth 1
        } else {
            # We increase the recursion of this tag
            dict with Status Tags $id { incr depth }
        }
	}

	set_help_text profile::tag_end [join {
		"Usage: profile::section_end <id>\n"
		"Ends a section."
	} {}]
	proc tag_end id {

        variable Status

        # If recursion depth reaches zero, the tag deactivation is complete, and metrics get updated.
        if {[dict get $Status Tags $id depth]==1} {

            
            set ts_begin [dict get $Status active_tags $id]
            set ts_end [machine_info time]
            
            dict set Status Tags $id depth 0
            dict with Status Tags $id { incr count }
            dict unset Status active_tags $id
                            
            set profile_level [dict get $Status Tags $id profile_level]
                        
            if {$profile_level < 1 && $ts_end-$ts_begin < 0.0001} { 
                
                return 
            }

            if {$profile_level < 2 && $ts_end-$ts_begin < 0.0020} { 

                set log_idx [dict get $Status log_idx]
                dict for {sub_id sub_ts_begin} [dict get $Status active_tags] {
                    dict set Status Tags $sub_id current_log $log_idx [list $id $ts_begin $ts_end]
                    incr log_idx
                }
                dict set Status log_idx $log_idx

                if {$profile_level < 1} { dict set Status Tags $id profile_level 1}
                return 
            }

        
            dict with Status Tags $id { 

                set previous_time_between_invocations [expr $ts_end-$previous_ts_end]
                
                set previous_ts_begin $ts_begin
                set previous_ts_end $ts_end
                set previous_duration [expr $previous_ts_end-$previous_ts_begin]
                
                set previous_log $current_log
                set current_log [dict create]
                
                if {$count==0} {
                    set max_duration $previous_duration
                    set avg_duration $previous_duration
                                              
                } else {                    

                    set previous_occupation [expr $previous_duration/$previous_time_between_invocations]

                    # We calculate the decay based on exponential mean.
                    set avg_halflife [dict get $Status avg_halflife]
                    set decay [expr $avg_halflife>0?pow(0.5,$previous_time_between_invocations/$avg_halflife):0]

                    set max_duration [expr $previous_duration>$max_duration?$previous_duration:$max_duration]
                    set avg_duration [expr $decay*$previous_duration + (1.-$decay)*$avg_duration]

                    set max_time_between_invocations [expr $previous_time_between_invocations>$max_time_between_invocations?$previous_time_between_invocations:$max_time_between_invocations]
                    set avg_time_between_invocations [expr $decay*$previous_time_between_invocations + (1.-$decay)*$avg_time_between_invocations]
                    
                    set max_occupation [expr $previous_occupation>$max_occupation?$previous_occupation:$max_occupation]
                    set avg_occupation [expr $decay*$previous_occupation + (1.-$decay)*$avg_occupation]       
                }
            }
            
            set ts_clean [expr {$ts_begin-1.0}]
            set log_idx [dict get $Status log_idx]
            dict for {sub_id sub_ts_begin} [dict get $Status active_tags] {
                
                if {$sub_ts_begin < $ts_clean} {
                    dict set Status Tags $sub_id depth 1
                    profile::tag_end $sub_id
                    disable $sub_id
                } else {
                    dict set Status Tags $id current_log $log_idx [list $sub_id $sub_ts_begin $ts_end]
                    incr log_idx
                    dict set Status Tags $sub_id current_log $log_idx [list $id $ts_begin $ts_end]
                    incr log_idx
                }
            }
            dict set Status log_idx $log_idx
            
            if {$profile_level < 2} { dict set Status Tags $id profile_level 2}
            return 

        } else {
            # If the tag had not been previously activated, its deactivation is ignored.
            if {[dict get $Status Tags $id depth]>0} {
                
                # We decrease the recursion depth of this tag.
                dict with Status Tags $id { incr depth -1}            
            }
        }
	}


# 
# Text interface:
#
        
        proc tui_print {} {
            variable Status
            foreach id [lsort [dict keys [dict get $Status Tags]]] {
                puts "$id: called [dict get $Status Tags $id count] times"
                puts stderr "$id: called [dict get $Status Tags $id count] times, [dict get $Status Tags $id depth]"
            }
        }
# 
# GUI interface:
#

    namespace eval gui {
        
        #
# VDP Helper Functions:
# TODO: Remove?

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


        # Gui_profile: description the GUI apparence.
        #    Are not dependent on the current content being executed. 
        #    Can be changed dynamically without affecting current profiling.
        variable Gui_profile {}
        variable Gui_profile_defaults [dict create \
            buttons [dict create] \
            width 150 \
            height 6 \
            font_mono "skins/DejaVuSansMono.ttf" \
            font_sans "skins/DejaVuSans.ttf" \
            unit % \
            avg_ratio 20 \
            current_help_widget "" \
            num_sections 0 \
            num_favorite_sections 0 \
            num_sections_in_usage 0 \
            selected_section "" \
            favorite_sections [dict create] \
            section_color [dict create] \
            next_color 0 \
            sorting_criteria "avg" \
            profile.all.ordering [dict create] \
            profile.favorite.ordering [dict create] \
            ]
        
        proc gui_add_button {widget on_press on_release on_activation upkeep help} {
            
            variable config
            dict set config buttons $widget [ dict create \
                activated 0 \
                on_press $on_press \
                on_release $on_release \
                on_activation $on_activation \
                upkeep $upkeep \
                help $help]
        }
                

        proc gui_on_mouse_button1_down {} {
            
            variable config
            dict for {widget button} [dict get $config buttons] {
                if {[gui_is_mouse_over $widget]} {
                    dict set config buttons $widget activated 1
                    eval [dict get $config buttons $widget on_press]
                }
            }
            after "mouse button1 up"   [namespace code gui_on_mouse_button1_up]
        }
        
        proc gui_on_mouse_button1_up {} {
            
            variable config
            dict for {widget button} [dict get $config buttons] {

                if {[gui_is_mouse_over $widget] && [dict get $config buttons $widget activated]} {
                    eval [dict get $config buttons $widget on_activation]
                }
                dict set config buttons $widget activated  0
                eval [dict get $config buttons $widget on_release]
            }
            after "mouse button1 down" [namespace code gui_on_mouse_button1_down]
        }
        
        proc gui_on_mouse_motion {} {
            
            variable config
            
            #if {![gui_is_mouse_over [dict get $config current_help_widget]]} {
            
                dict for {widget button} [dict get $config buttons] {
                    if {[gui_is_mouse_over $widget]} {
                        
                        osd configure profile.config.info.text -text [dict get $config buttons $widget help]
                        dict set config current_help_widget $widget
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
            

            variable config
            
            set w [dict get $config width]
            set h [dict get $config height]
            
            #
            # Helper Subfunctions
            #

            # Scroll Buttons
            proc add_scroll_button {parent icon1 icon2 upkeep1 upkeep2} {

                variable config
                
                set w [dict get $config width]
                set h [dict get $config height]
                
                osd create rectangle $parent.scroll -relx 1.0 -w [expr -1*$h] -h $h -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF
                osd create text      $parent.scroll.text -x [expr 1.5*$h/6.-$h] -y [expr -0.25*$h/6.] -size [expr 5*$h/6] -rgba 0x000000FF \
                    -font [dict get $config font_mono] -text $icon2

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
                        variable config
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
                
                variable config
                
                set w [dict get $config width]
                set h [dict get $config height]
                
                osd create rectangle profile.config.$name  -x [expr $x*$w/4.] -y [expr ($y+1)*$h] -w [expr $w/4-0.1*$h] -h [expr 0.9*$h] -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF
                osd create text      profile.config.$name.text -x [expr 1.5*$h/6.] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xFFFFFFFF \
                    -font [dict get $config font_sans] -text [eval $text]

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
                set w [dict get $config width]
                set h [dict get $config height]
                osd configure profile -x [expr {0.6*[osd info profile -x]+0.4*(-$w+$h)}] 
            } { 
                osd configure profile -x [expr {0.6*[osd info profile -x]+0.4*0}] 
            }
                
            #
            # Section: Configuration
            osd create rectangle profile.config -y $h -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
            osd create text      profile.config.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                -text "Configuration"

            add_scroll_button profile.config "\u25BC" "\u25B2" {
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
            } { 
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*5*[dict get $config height]}]
            }
                
            
            add_config_button sort  0 0 {format "Sort:"} {} "Sort"
            add_config_button unit  1 0 {format "Unit:"} {} "Unit"
            add_config_button z80i  2 0 {format "Z80i:"} {} "z80i"
            add_config_button file  3 0 {format "File:"} {} "File"
            add_config_button pause 0 1 {format "Pause:"} {} "Pause"
            add_config_button clear 1 1 {format "Clear:"} {} "Clear"
            add_config_button avg   2 1 {format "Avg:"} {} "Avg"
            add_config_button hsize   3 1 {format "H Size: %d" [dict get $config height]} {
                variable config
                dict set config height [expr 5+([dict get $config height]+1-5)%3]
                osd destroy profile
                gui_create
            } "Toggles text Size between 5, 6, and 7"

            osd create rectangle profile.config.info  -x [expr 0*$w/4.] -y [expr (2+1)*$h] -w [expr $w-0.1*$h] -h [expr 1.9*$h] -rgba 0x40404080
            osd create text      profile.config.info.text -x [expr 1.5*$h/6.] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xC0C0C0FF \
                    -font [dict get $config font_sans] -text "Command Info"

            after "mouse motion" [namespace code gui_on_mouse_motion]

            
            #
            # Section: All Tags
            osd create rectangle profile.all -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
            osd create text      profile.all.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                -text "All Tags"

            add_scroll_button profile.all "\u25BC" "\u25B2" {
                osd configure profile.all -y [expr {[osd info profile.config -y] + [osd info profile.config -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
            } { 
                osd configure $parent -y [expr {[osd info profile.config -y] + [osd info profile.config -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*(1+[dict get $config num_sections])*[dict get $config height]}]
            }

            #
            # Section: Favorite Tags
            osd create rectangle profile.favorite -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
            osd create text      profile.favorite.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                -text "Favorite Tags"

            add_scroll_button profile.favorite "\u25BC" "\u25B2" {
                osd configure $parent -y [expr {[osd info profile.all -y] + [osd info profile.all -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
            } { 
                osd configure $parent -y [expr {[osd info profile.all -y] + [osd info profile.all -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*(1+[dict get $config num_favorite_sections])*[dict get $config height]}]
            }
            
            
            #
            # Section: Info
            osd create rectangle profile.info -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
            osd create text      profile.info.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                -text "Information:"

            add_scroll_button profile.info "\u25BC" "\u25B2" {
                osd configure $parent -y [expr {[osd info profile.favorite -y] + [osd info profile.favorite -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
            } { 
                osd configure $parent -y [expr {[osd info profile.favorite -y] + [osd info profile.favorite -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*5*[dict get $config height]}]
            }

            #
            # Section: Usage and Timeline
            osd create rectangle profile.detailed -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
            osd create text      profile.detailed.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                -text "Usage and Timeline:"

            add_scroll_button profile.detailed "\u25BC" "\u25B2" {
                osd configure $parent -y [expr {[osd info profile.info -y] + [osd info profile.info -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
            } { 
                osd configure $parent -y [expr {[osd info profile.info -y] + [osd info profile.info -h]}]                
                osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*(5+[dict get $config num_sections_in_usage])*[dict get $config height]}]
            }
            
            osd create rectangle profile.detailed.timeline_cpu -y [expr 1.*$h] -w $w -h [expr 2.*$h] -clip true
            osd create rectangle profile.detailed.timeline_vdp -y [expr 3.*$h] -w $w -h [expr 2.*$h] -clip true
            osd create rectangle profile.detailed.usage -y [expr 5.*$h] -w $w -relh 1 -clip true -rgba 0x00000088        
            gui_update
        }

        proc gui_get_color {id} {
            
            variable config
            if {[dict exists $config section_color $id]} {
                set idx [dict get $config section_color $id]
            } else {
                set idx [dict get $config next_color]
                dict incr config next_color
                dict set config section_color $id $idx
            } 

            proc fraction_to_uint8 {value} {
                set value [expr {round($value * 255)}]
                expr {$value > 255 ? 255 : $value < 0 ? 0 : $value}
            }
            
            set h [expr $idx / 7.]
            set y [expr 0.20 + 0.2 * ($idx % 2) ]
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

        proc gui_add_info_bar {parent id} {
            
            variable config
            set w [dict get $config width]
            set h [dict get $config height]
            set fs [dict get $config font_sans]
            set fm [dict get $config font_mono]
            osd create rectangle $parent.$id -x 0 -y [expr -2*$h] -w $w -h $h -clip true -rgba 0x00000088
            osd create rectangle $parent.$id.bar -x 0 -y 0 -w 0 -h $h -rgba [gui_get_color $id]
                    
            osd create rectangle $parent.$id.favorite -x [expr 0*$h] -h $h -w $h -rgba 0x00000000
            osd create text $parent.$id.favorite.text -x [expr 0.125*$h] -y [expr  0.125*$h/6.] -size [expr 5*$h/6] -rgba 0xffffffff -font $fs  -text "\u2606"
            gui_add_button $parent.$id.favorite \
                "eval { osd configure $parent.$id.favorite -rgba 0xFFFFFF40 } " \
                "eval { osd configure $parent.$id.favorite -rgba 0xFFFFFF00 } " \
                "variable config
                if {\[dict exist \$config favorite_sections $id]} {
                    dict unset config favorite_sections $id
                } else {
                    dict set config favorite_sections $id 1
                }" \
                "variable config
                if {\[dict exist \$config favorite_sections $id]} {
                    osd configure $parent.$id.favorite.text -text \"\\u2605\"
                } else {
                    osd configure $parent.$id.favorite.text -text \"\\u2606\"
                }
                set target \[expr \[dict get \$config $parent.ordering $id]*\[dict get \$config height]]
                osd configure $parent.$id -y \[expr {0.6*\[osd info $parent.$id -y]+0.4*\$target}]
                " \
                "Add/Remove $id to the favorites list" 


            osd create rectangle $parent.$id.select -x [expr 1*$h] -h $h -w $h -rgba 0x00000000
            osd create text $parent.$id.select.text -x [expr 0.125*$h] -y [expr -0.125*$h/6.] -size [expr 5*$h/6] -rgba 0xffffffff -font $fs  -text "\u25CE"
            gui_add_button $parent.$id.select \
                "osd configure $parent.$id.select -rgba 0xFFFFFF40 " \
                "osd configure $parent.$id.select -rgba 0xFFFFFF00 " \
                "eval { 
                variable config
                dict set config selected_section \"$id\" 
                gui_update_details \"$id\"
                } " \
                "eval { 
                variable config                        
                if { \[dict get \$config selected_section] == \"$id\" } {
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
                "osd configure $parent.$id.max -rgba 0xFFFFFF40 " \
                "osd configure $parent.$id.max -rgba 0xFFFFFF00 " \
                "variable sections \n dict set sections $id section_time_max 0" \
                "variable sections
                osd configure $parent.$id.max.text -text \[format \"max:%s\" \[gui_to_unit \[dict get \$sections $id section_time_max]]]" \
                "Maximum duration of section: $id
                Click to reset." 

            osd create text $parent.$id.name     -x [expr 12*$h] -y [expr   0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xffffffff -font $fs -text $id
                            
        }

        
        proc gui_update_details {id} {
            
            variable config
            variable sections

            set w [dict get $config width]
            set h [dict get $config height]
            osd destroy profile.detailed.timeline_cpu
            osd destroy profile.detailed.timeline_vdp
            osd destroy profile.detailed.usage

            foreach button [dict keys [dict get $config buttons] profile.detailed.{*}] { dict unset config buttons $button }

            osd create rectangle profile.detailed.timeline_cpu -y [expr 1.*$h] -w $w -h [expr 2.*$h] -clip true
            osd create rectangle profile.detailed.timeline_vdp -y [expr 3.*$h] -w $w -h [expr 2.*$h] -clip true
            osd create rectangle profile.detailed.usage -y [expr 5.*$h] -w $w -relh 1 -clip true -rgba 0x00000088       
            if {[dict exists $sections $id]} {
                
                osd configure profile.detailed.text -text [format "Usage and Timeline: %s" $id]
                osd configure profile.info.text -text [format "Information: %s" $id]
                

                if {[dict exists $sections $id last_log]} {
                    
                    set ts_begin_parent [dict get $sections $id last_log_ts_begin]
                    set ts_end_parent [dict get $sections $id last_log_ts_end]
                    set td_parent [expr {$ts_end_parent-$ts_begin_parent}]
                    puts stderr [format "Parent: %s %7.5f" $id $td_parent]
                    set idx 0
                    set depth_level 0
                    set subsections [dict create]

                    foreach {sub_id type timestamp} [dict get $sections $id last_log] {

                        if {![dict exists $subsections $sub_id]} {
                            dict set subsections $sub_id [dict create \
                                num_invocations 0 \
                                total_time 0.0 \
                                ts_begin 0.0 \
                                depth $depth_level \
                            ]
                            incr depth_level
                        }
                        
                        if {$type=="begin"} {                        
                            dict with subsections $sub_id { incr num_invocations }
                            dict set  subsections $sub_id ts_begin $timestamp
                            
                        } elseif {$type=="end"} {                        
                            set  ts_begin [dict get $subsections $sub_id ts_begin]
                            set  ts_end $timestamp
                            set  td [expr $ts_end-$ts_begin]
                            puts stderr [format "Sub: %s %7.5f" $sub_id $td_parent]
                                                    
                            dict with subsections $sub_id { set total_time [expr $total_time+$ts_end-$ts_begin]}

                            incr idx
                            set timeline_bar_name [format "profile.detailed.timeline_cpu.bar%03d" $idx]
                            osd create rectangle $timeline_bar_name -x 0 -y 0 -w 0 -h [expr 2*$h] -rgba [gui_get_color $sub_id]
                            puts stderr [format "w: %s %s %s %s" $ts_end $ts_begin $td_parent ($ts_end-$ts_begin)]
                            osd configure $timeline_bar_name -x [expr $w*($ts_begin-$ts_begin_parent)/$td_parent]
                            osd configure $timeline_bar_name -w [expr $w*($ts_end-$ts_begin)/$td_parent]

                            set usage_bar_name [format "profile.detailed.usage.bar%03d" $idx]
                            osd create rectangle $usage_bar_name -x 0 -y [expr [dict get $subsections $sub_id depth]*$h] -w 0 -h [expr 1*$h] -rgba [gui_get_color $sub_id]
                            osd configure $usage_bar_name -x [expr $w*($ts_begin-$ts_begin_parent)/$td_parent]
                            osd configure $usage_bar_name -w [expr $w*($ts_end-$ts_begin)/$td_parent]
                        }
                    }
                    
                    set idx 0
                    dict for {sub_id subsection}  $subsections {
                        incr idx
                        set usage_text_time [format "profile.detailed.usage.time%03d" $idx]
                        osd create text $usage_text_time -x [expr 0.125*$h] -y [expr (0.5/6 + [dict get $subsections $sub_id depth])*$h] \
                            -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_mono] \
                            -text [format "T:%s" [gui_to_unit [dict get $subsections $sub_id total_time]]]

                        set usage_text_name [format "profile.detailed.usage.name%03d" $idx]
                        osd create text $usage_text_name -x [expr 4.125*$h] -y [expr (0.5/6 + [dict get $subsections $sub_id depth])*$h] \
                            -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                            -text $sub_id
                            
                    }
                    
                
                    dict set config num_sections_in_usage $depth_level
                }
            }
        }
        
        

        proc gui_update {} {

            variable config
            
            # aim for a maximum update rate of 50Hz
            #if {[machine_info time] < [dict get $config last_updated] + 0.02 } return
            #dict set config last_updated [machine_info time]

            # no need to update if there is no profile to update
            if {![osd exists profile]} return
            
            # perform upkeep actions (i.e., smooth transitions)
            dict for {widget button} [dict get $config buttons] { eval [dict get $button upkeep] }
            
            # Update All and Favorite Sections
            proc sort_sections {ids} {
            
                variable config
                if {[dict get $config sorting_criteria] == "avg"} {
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
            set idx 0
            foreach id [sort_sections [dict keys $sections]] {
                set idx [expr 1+$idx]
                dict set config profile.all.ordering $id $idx
                dict set config profile.favorite.ordering $id -5
                if {![osd exists profile.all.$id]} { 
                    gui_add_info_bar profile.all $id
                    gui_add_info_bar profile.favorite $id
                }
            }
            dict set config num_sections $idx

            set idx 0
            foreach id [sort_sections [dict keys [dict get $config favorite_sections]]] {
                set idx [expr 1+$idx]
                dict set config profile.favorite.ordering $id $idx
            }
            dict set config num_favorite_sections $idx        
        
            after "20" profile::gui_update
        }
        


        proc gui_to_unit {seconds} {
            variable config
            set unit [dict get $config unit]

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
            if {$enable && ![osd exists profile]} { 
                gui_create
            }
            if {!$enable && [osd exists profile]} { 
                osd destroy profile
                variable config
                dict set config buttons [dict create]
            }
            return
        }

        set_help_text profile_break [join {
            "Usage: profile_break <ids>\n"
            "Breaks execution at the start of the section."
        } {}]
        proc profile_break {ids} {
            variable sections
            foreach id $ids {
                dict with sections $id {
                    set break true
                    debug cont
                }
            }
        }
        
        proc profile_break_tab {args} {
            if {[llength $args] == 2} { return [section_list] }
        }
        set_tabcompletion_proc profile_break [namespace code profile_break_tab]


    }
}

namespace import profile::*
