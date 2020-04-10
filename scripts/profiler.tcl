
namespace eval profiler {
    
    namespace eval core {

        if ![info exists Status] { variable Status [dict create] }
        if ![info exists Configuration] { variable Configuration [dict create] }

        proc start {} {
            
            variable Status
            if {[dict size $Status]==0} {
                
                set Status [defaults::Status]

                variable Configuration
                if {[dict size $Configuration]==0} {set Configuration [defaults::Configuration]}
                                
                tag::create "irq"
                callback::add_tag "irq" set_bp 0x38 {} {::profiler::core::irq::cb}
                
                tag::create "vdp"
                callback::add_tag "vdp" probe set_bp VDP.commandExecuting {} {::profiler::core::vdp::cb}
                
                callback::add set_condition {} {::profiler::core::auto_scan::cb}   
            }
            return
        }          

        proc stop {} {
            
            variable Status
                        
            if {![dict exists $Status debug_cb]} return
            dict for {idx cb_id} [dict get $Status debug_cb] { callback::remove $cb_id }
            
            if {![dict exists $Status Tags]} return
            dict for {tag_id val} [dict get $Status Tags] { tag::delete $tag_id } 
            
            set Status [dict create]
            return
        }

        proc resetConfiguration {} {
            
            variable Configuration
            set Configuration [defaults::Configuration]
            return
        }

        namespace eval defaults {
            
            proc Status {} { return [dict create \
                Tags [dict create] \
                call_stack [dict create] \
                log_idx 0 \
                debug_cb [dict create] \
                debug_cb_idx 0 \
                active_tags [dict create] \
                selected_tag {} \
            ]}

            proc Configuration {} { return [dict create \
                auto_scan 0 \
                favorite_tags [dict create] \
                avg_halflife 1 \
                z80_interface_enabled 0 \
                z80_section_name_address 0xF931 \
            ]}

            proc Tag {} { return [dict create \
                hash {} \
                debug_cb [dict create] \
                profiler_level 0 \
                disabled 0 \
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
            ]}
        }

        namespace eval callback {

            proc remove cb_id {
                                
                lassign [split $cb_id #] type num
                switch $type {
                    bp   { debug remove_bp $cb_id }
                    wp   { debug remove_watchpoint $cb_id }
                    cond { debug remove_condition $cb_id }
                    pp   { debug probe remove_bp $cb_id }
                    default { error [format "Unknown debug type: %s" $cb_id] }
                }
            }

            proc add {args} {
                
                namespace upvar ::profiler::core Status Status
                
                set idx [dict get $Status debug_cb_idx]
                incr idx
                dict set Status debug_cb_idx $idx
                
                dict set Status debug_cb $idx [debug {*}$args ]
                return
            }

            proc add_once {args} {
                
                namespace upvar ::profiler::core Status Status
                                        
                set idx [dict get $Status debug_cb_idx]
                incr idx
                dict set Status debug_cb_idx $idx

                dict set Status debug_cb $idx [debug {*}[lreplace $args end end "                    
                    [lindex $args end]
                    profiler::core::callback::remove \[dict get \$profiler::core::Status debug_cb $idx]
                    dict unset profiler::core::Status debug_cb $idx
                "]]
                return
            }

            proc add_tag {tag_id args} {
                
                namespace upvar ::profiler::core Status Status
                
                set idx [dict get $Status debug_cb_idx]
                incr idx
                dict set Status debug_cb_idx $idx

                dict set Status debug_cb $idx [debug {*}[lreplace $args end end "                    
                    set tag_id $tag_id
                    [lindex $args end]
                "]]
            }

            proc add_tag_once {tag_id args} {
                
                namespace upvar ::profiler::core Status Status
                                        
                set idx [dict get $Status debug_cb_idx]
                incr idx
                dict set Status debug_cb_idx $idx

                dict set Status Tags $tag_id debug_cb $idx [debug {*}[lreplace $args end end "
                    set tag_id $tag_id                 
                    [lindex $args end]
                    profiler::core::callback::remove \[dict get \$profiler::core::Status Tags $tag_id debug_cb $idx]
                    dict unset profiler::core::Status Tags $tag_id debug_cb $idx
                "]]
            }
        }

        namespace eval irq {
            proc cb {} {
                ::profiler::core::tag::begin "irq"
                ::profiler::core::callback::add_tag_once "irq" set_watchpoint read_mem [reg sp] {} {
                    ::profiler::core::tag::end "irq"
                }                
            }
        }

        namespace eval vdp {
            proc cb {} {
                if [debug probe read VDP.commandExecuting] {
                    ::profiler::core::tag::begin "vdp"
                } else {
                    ::profiler::core::tag::end "vdp"
                }
            }
        }

        namespace eval tag {


            proc disable tag_id {

                puts stderr "Disabling $tag_id"
                
                namespace upvar ::profiler::core Status Status
                
                dict set Status Tags $tag_id disabled 1
                dict for {idx cb_id} [dict get $Status Tags $tag_id debug_cb] { remove_cb $cb_id }
                dict set Status Tags $tag_id debug_cb [dict create]
            }

            proc create tag_id {

                namespace upvar ::profiler::core Status Status
                
                if {![dict exists $Status Tags $tag_id]} {
                    dict set Status Tags $tag_id [::profiler::core::defaults::Tag]
                }
            }

            proc delete tag_id {
                
                namespace upvar ::profiler::core Status Status
                
                if {![dict exists $Status Tags $tag_id]} return
                
                dict for {idx cb_id} [dict get $Status Tags $tag_id debug_cb] { 
                    ::profiler::core::callback::remove $cb_id 
                }
                
                dict unset Status Tags $tag_id
                dict unset Status active_tags $tag_id
            }

            proc begin tag_id {
                        
                namespace upvar ::profiler::core Status Status
                
                # If the tag that wasn't active gets activated, we register the activation
                if {[dict get $Status Tags $tag_id depth]==0} {

                    # We add the tag to the list of active tags
                    dict set Status active_tags $tag_id [machine_info time]
                    dict set Status Tags $tag_id depth 1
                } else {
                    # We increase the recursion of this tag
                    dict with Status Tags $tag_id { incr depth }
                }
            }

            proc end tag_id {

                namespace upvar ::profiler::core Status Status
                namespace upvar ::profiler::core Configuration Configuration

                # If recursion depth reaches zero, the tag deactivation is complete, and metrics get updated.
                if {[dict get $Status Tags $tag_id depth]==1} {
                    
                    set ts_begin [dict get $Status active_tags $tag_id]
                    set ts_end [machine_info time]
                    
                    dict set Status Tags $tag_id depth 0
                    dict with Status Tags $tag_id { incr count }
                    dict unset Status active_tags $tag_id
                                    
                    set profiler_level [dict get $Status Tags $tag_id profiler_level]
                                
                    if {$profiler_level < 1 && $ts_end-$ts_begin < 0.0001} {                         
                        return 
                    }

                    if {$profiler_level < 2 && $ts_end-$ts_begin < 0.0050} { 

                        set log_idx [dict get $Status log_idx]
                        dict for {sub_id sub_ts_begin} [dict get $Status active_tags] {
                            dict set Status Tags $sub_id current_log $log_idx [list $tag_id $ts_begin $ts_end]
                            incr log_idx
                        }
                        dict set Status log_idx $log_idx

                        if {$profiler_level < 1} { dict set Status Tags $tag_id profiler_level 1}
                        return 
                    }

                
                    dict with Status Tags $tag_id { 

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
                            set avg_halflife [dict get $Configuration avg_halflife]
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
                            end $sub_id
                            disable $sub_id
                        } else {
                            dict set Status Tags $tag_id current_log $log_idx [list $sub_id $sub_ts_begin $ts_end]
                            incr log_idx
                            dict set Status Tags $sub_id current_log $log_idx [list $tag_id $ts_begin $ts_end]
                            incr log_idx
                        }
                    }
                    dict set Status log_idx $log_idx
                    
                    if {$profiler_level < 2} { dict set Status Tags $tag_id profiler_level 2}
                    return 

                } else {
                    # If the tag had not been previously activated, its deactivation is ignored.
                    if {[dict get $Status Tags $tag_id depth]>0} {
                        
                        # We decrease the recursion depth of this tag.
                        dict with Status Tags $tag_id { incr depth -1}            
                    }
                }
            }

            proc abort tag_id {
                abort $tag_id
            }
        }                        

        namespace eval auto_scan {
            
            proc get_function_hash {address} {
                
                append hash0 [debug read memory $address]
                incr address
                append hash1 [debug read memory $address]
                incr address
                append hash2 [debug read memory $address]
                return [format "%02X%02X%02X" $hash0 $hash1 $hash2]
            }

            proc tentative_call {pc instr} {

                namespace upvar ::profiler::core Status Status
                
                # CD CALL 
                if {$instr == 0xCD} { 
                    set target_address [peek16 [expr {$pc+1}]]
                    set return_address [expr {$pc+3}]
                } elseif {($instr & 0xC7) == 0xC4} {
                    set f [debug read "CPU regs" 1]
                    # C4 CALL_NZ 
                    if       {$instr == 0xC4} { if {($f & 0x40) != 0} return  
                    # D4 CALL_NC 
                    } elseif {$instr == 0xD4} { if {($f & 0x01) != 0} return 
                    # E4 CALL_PO4
                    } elseif {$instr == 0xE4} { if {($f & 0x04) != 0} return 
                    # F4 CALL_P
                    } elseif {$instr == 0xF4} { if {($f & 0x80) != 0} return 
                    # CC CALL_Z
                    } elseif {$instr == 0xCC} { if {($f & 0x40) == 0} return 
                    # DC CALL_C
                    } elseif {$instr == 0xDC} { if {($f & 0x01) == 0} return 
                    # EC CALL_PE
                    } elseif {$instr == 0xEC} { if {($f & 0x04) == 0} return 
                    # FC CALL_M
                    } elseif {$instr == 0xFC} { if {($f & 0x80) == 0} return } 

                    set target_address [peek16 [expr {$pc+1}]]
                    set return_address [expr {$pc+3}]
                } elseif {($instr & 0xC7) == 0xC7} {
                    # RST
                    set target_address [expr {$instr - 0xC7}]
                    set return_address [expr {$pc+1}]
                } else {
                    return
                }
                
                set tag_id [format "0x%04x_#%s" $target_address [get_function_hash $target_address]]
                ::profiler::core::tag::create $tag_id
                
                if {[dict size [dict get $Status Tags $tag_id debug_cb]]>4} { disable $tag_id }
                if [dict get $Status Tags $tag_id disabled] { return }
                
                set stack_idx [dict size [dict get $Status call_stack]]
                set stack_address [expr [reg sp]-2]
                while {$stack_idx>0} {
                    lassign [dict get $Status call_stack [expr {$stack_idx-1}]] previous_stack_address previous_return_address
                    if {$previous_stack_address > $stack_address} { break }
                    #puts stderr "Clean stack"
                    dict unset Status call_stack [expr {$stack_idx-1}]
                    incr stack_idx -1
                }
                dict set Status call_stack $stack_idx [list $stack_address $return_address $tag_id]
                
                ::profiler::core::tag::begin $tag_id      
            }

            proc tentative_ret {pc instr} {

                namespace upvar ::profiler::core Status Status

                # C9 RET
                if {$instr == 0xC9} { 
                } elseif {($instr & 0xC7) == 0xC0} {
                    set f [debug read "CPU regs" 1]
                    # C0 RET_NZ 
                    if       {$instr == 0xC0} { if {($f & 0x40) != 0} return  
                    # D0 RET_NC 
                    } elseif {$instr == 0xD0} { if {($f & 0x01) != 0} return 
                    # E0 RET_PO
                    } elseif {$instr == 0xE0} { if {($f & 0x04) != 0} return 
                    # F0 RET_P
                    } elseif {$instr == 0xF0} { if {($f & 0x80) != 0} return 
                    # C8 RET_Z
                    } elseif {$instr == 0xC8} { if {($f & 0x40) == 0} return 
                    # D8 RET_C
                    } elseif {$instr == 0xD8} { if {($f & 0x01) == 0} return 
                    # E8 RET_PE
                    } elseif {$instr == 0xE8} { if {($f & 0x04) == 0} return 
                    # F8 RET_M
                    } elseif {$instr == 0xF8} { if {($f & 0x80) == 0} return } 
                } else {
                    return
                }
                
                
                set sp [reg sp]
                set return_address [peek16 $sp]
                set stack_idx [expr {[dict size [dict get $Status call_stack]]-1}]
                
                if {$stack_idx>=0} {
                    
                    lassign [dict get $Status call_stack $stack_idx] expected_sp expected_return_address expected_id
                    
                    if { $sp<$expected_sp } {
                        #probably it is a retun from interrupt
                    } elseif { ($expected_return_address == $return_address) && ($expected_sp == $sp) } {

                        dict unset Status call_stack $stack_idx
                        ::profiler::core::tag::end $expected_id
                        #puts stderr "Ret OK! $stack_idx"
                    } else {

                        set new_call_stack [dict create]
                        set clean 1
                        dict for {idx info} [dict get $Status call_stack] {
                            lassign $info e_sp e_r_address e_id
                            if $clean {
                                if {$e_sp==$sp} {
                                    if {$e_r_address==$return_address} {
                                        ::profiler::core::tag::end $e_id
                                        puts stderr "Found buried return"
                                    } else {
                                        ::profiler::core::tag::abort $e_id
                                        puts stderr "Wrong buried return"
                                    }
                                    set clean 0
                                    break
                                }
                                set a_r_address [peek16 $e_sp]
                                #puts stderr [format "#%02d : #0x%04X: 0x%04X -> 0x%04X" $idx $e_sp $e_r_address $a_r_address]
                                
                                if {$e_r_address == $a_r_address} {
                                    dict set new_call_stack [dict size $new_call_stack] $info
                                } else {
                                    ::profiler::core::tag::abort $e_id
                                    set clean 0                                        
                                }
                            } else {
                                ::profiler::core::tag::abort $e_id
                            }
                        }

                        dict set Status call_stack $new_call_stack
                    }
                }
            }

            proc cb {} {

                namespace upvar ::profiler::core Configuration Configuration
                
                if {![dict get $Configuration auto_scan]} { return }
                                
                set pc [expr {256 * [debug read "CPU regs" 20] + [debug read "CPU regs" 21]}]
                set instr [debug read memory $pc]
                
                # Shortcut: neither a Call or a Ret
                if {($instr & 0xC0) != 0xC0} { return }


                if {($instr & 0x04) == 0x04} {
                    tentative_call $pc $instr
                } else {
                    tentative_ret $pc $instr
                }

            }
        }

        # TODO
        namespace eval z80 {

            # 
            # Z80 interface:


                set_help_text profiler::get_debug_string [join {
                    "Usage: profiler::get_debug_string <address>\n"
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
                
                set_help_text profiler::enable_z80_interface [join {
                    "Usage: profiler::begin_z80_interface \[<begin_port>] \[<end_port>] \[<section_name_address>]\n"
                    "Enables the z80 interface."
                    "To begin a section, write the pointer to the section name to address <section_name_address>, and then send any byte to the I/O port <begin_port>."
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

                set_help_text profiler::enable_z80_self_estimation [join {
                    "Usage: profiler::enable_z80_self_estimation \[<begin_port>] \[<end_port>] \[<section_name_address>] \[<time_unit>]\n"
                    "Enables the z80 self estimaton feature."
                    "This code is useful when we design z80 code that keeps track of the time that has passed since the VDP interruption begined."
                    "In this case, you must write the time that has passed to the I/O ports when begining or ending a section."
                    "The default unit is 1/6000 of a second, i.e., 1 percent of the frame time at 60 Hz, but it can be set to any value."
                } {}]
                proc enable_z80_self_estimation { {time_unit {[expr 1 / 6000]}} } {
                    
                    variable z80_self_estimation_time_unit
                    set z80_self_estimation_time_unit $time_unit
                }
            
        }

    }

    proc reset {} { core::stop; core::start }
    proc stop {} { core::stop }
    proc start {} { core::start }

    proc reload {} {
        source [dict get [info frame 0] file]
        reset
    }

    namespace eval auto_scan {
        proc enable {} {
            ::profiler::start
            dict set ::profiler::core::Configuration auto_scan 1
            return
        }

        proc disable {} {
            dict set ::profiler::core::Configuration auto_scan 0
            return
        }
    }

    namespace eval breakpoints {

        set_help_text profiler::breakpoints::address_begin [join {
            "Usage: profiler::breakpoints::address_begin_bp <tag_id> <address> \[<condition>]\n"
            "Define a breakpoint which begins a section."
        } {}]
        proc address_begin {tag_id address {condition {}}} {
            
            ::profiler::start
            ::profiler::core::tag::create $tag_id
            ::profiler::core::callback::add_tag $tag_id set_bp $address $condition {
                ::profiler::core::tag::begin $tag_id
            }                
        }

        set_help_text profiler::breakpoints::address_end [join {
            "Usage: profiler::breakpoints::address_end <tag_id> <address> \[<condition>]\n"
            "Define a breakpoint which ends a section."
        } {}]
        proc address_end {tag_id address {condition {}}} {
            
            ::profiler::start
            ::profiler::core::tag::create $tag_id
            ::profiler::core::callback::add_tag $tag_id set_bp $address $condition {
                ::profiler::core::tag::end $tag_id
            }                
        }

        set_help_text profiler::breakpoints::address_scope [join {
            "Usage: profiler::breakpoints::address_scope <tag_id> <address> \[<condition>]\n"
            "Define a breakpoint which begins a section, and will end it after the "
            "value on the top of the stack is read, typically when the method "
            "returns or when it is popped. Useful for profiling function calls."
        } {}]
        proc address_scope {tag_id address {condition {}}} {

            ::profiler::start
            ::profiler::core::tag::create $tag_id
            ::profiler::core::callback::add_tag $tag_id set_bp $address $condition {
                ::profiler::core::tag::begin $tag_id
                ::profiler::core::callback::add_tag_once $tag_id set_watchpoint read_mem [reg sp] {} {
                    ::profiler::core::tag::end $tag_id
                }
            }
        }
    }


# 
# Text interface:
#
    namespace eval tui {
        
        namespace upvar ::profiler::core Status Status

        proc print {} {
            variable Status
            foreach id [lsort [dict keys [dict get $Status Tags]]] {
                puts "$id: called [dict get $Status Tags $id count] times"
                puts stderr "$id: called [dict get $Status Tags $id count] times, [dict get $Status Tags $id depth]"
            }
        }
    }


# 
# GUI interface:

    namespace eval gui {
        
        proc start {} {

            ::wm::widget add "wm.profiler" rectangle osd_relw 1 osd_relh 1 osd_rgba 0x00000000 osd_clip true

            ::wm::widget add "wm.profiler.dock" dock 
            
            ::wm::widget add "wm.profiler.dock.panel.control" ::profiler::gui::widgets::control_window 
#            ::wm::widget add "wm.profiler.dock.panel.favorite_tags" ::profiler::gui::widgets::main_detected_tags_window 
            ::wm::widget add "wm.profiler.dock.panel.last_detected_tags" ::profiler::gui::widgets::last_detected_tags_window 
            ::wm::widget add "wm.profiler.dock.panel.info_window_docked" ::profiler::gui::widgets::info_window_docked 
            ::wm::widget add "wm.profiler.dock.panel.timeline_window_docked" ::profiler::gui::widgets::timeline_window_docked
        }
        

        namespace eval util {
            if {0} {
            namespace util sort {
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
            }


            namespace eval units {

                proc to_unit {seconds} {
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
            }

            }
        
            proc get_tag_rgba {tag_id} {
                
                if {[dict exists $::wm::Status tag_rgba $tag_id]} {
                    return [dict get $::wm::Status tag_rgba $tag_id]
                }
                
            
                proc yuva_to_rgba {y u v a} {

                    proc fraction_to_uint8 {value} {
                        set value [expr {round($value * 255)}]
                        expr {$value > 255 ? 255 : $value < 0 ? 0 : $value}
                    }
                    
                    set r [fraction_to_uint8 [expr {$y + 1.28033 * 0.615 * $v}]]
                    set g [fraction_to_uint8 [expr {$y - 0.21482 * 0.436 * $u - 0.38059 * 0.615 * $v}]]
                    set b [fraction_to_uint8 [expr {$y + 2.12798 * 0.436 * $u}]]
                    set a [fraction_to_uint8 $a]
                    expr {$r << 24 | $g << 16 | $b << 8 | $a}
                }        

                set idx [zlib crc32 $tag_id]                
                set h [expr $idx / 7.]
                set y [expr 0.20 + 0.2 * ($idx % 2) ]
                set a 1
                
                set h [expr {($h - floor($h)) * 8.0}]
                set rgba [yuva_to_rgba $y [expr {$h < 2.0 ? -1.0 : $h < 4.0 ? $h - 3.0 : $h < 6.0 ? 1.0 : 7.0 - $h}] \
                            [expr {$h < 2.0 ? $h - 1.0 : $h < 4.0 ? 1.0 : $h < 6.0 ? 5.0 - $h : -1.0}] $a]
                
                if {![dict exists $::wm::Status tag_rgba]} {
                    dict exists ::wm::Status tag_rgba [dict create]                    
                }
                dict set ::wm::Status tag_rgba $rgba
                
                return $rgba
            }


            proc clamp01 {val} { return [expr {$val<0?0:$val>1?1:$val}] }

            namespace eval vdp {

                proc get_frame_duration {} {
                    expr {(1368.0 * (([vdpreg 9] & 2) ? 313 : 262)) / (6 * 3579545)}
                }

                proc get_start_of_frame_time {} {
                    expr {[machine_info time] - [machine_info VDP_cycle_in_frame] / (6.0 * 3579545)}
                }
                proc get_time_since_VDP_start {} {
                    expr {[machine_info VDP_cycle_in_frame] / (6.0 * 3579545)}
                }   
            }
            


    ########################################################################                

        }        
        
        
        
        namespace eval widgets {

            proc control_window {path args} {
            
                ::wm::widget add $path docked_window                
                ::wm::widget add $path.panel.sort dropdown_button
                ::wm::widget add $path.panel.bar dropdown_button
                ::wm::widget add $path.panel.info dropdown_button
                ::wm::widget add $path.panel.scope dropdown_button
                ::wm::widget add $path.panel.z80 toggle_button
                ::wm::widget add $path.panel.auto_scan toggle_button
                ::wm::widget add $path.panel.reset button
                ::wm::widget add $path.panel.pause toggle_button
                
                
                
                ::wm::widget rset $path \
                    title.text.osd_text "Controls" \
                    panel.sort.osd_x  {[expr {0.1*$sz}]} \
                    panel.sort.osd_y  {[expr {0.1*$sz}]} \
                    panel.sort.osd_w  {[expr {7*$sz}]} \
                    panel.bar.osd_x   {[expr {0.1*$sz}]} \
                    panel.bar.osd_y   {[expr {1.1*$sz}]} \
                    panel.bar.osd_w   {[expr {7*$sz}]} \
                    panel.info.osd_x  {[expr {0.1*$sz}]} \
                    panel.info.osd_y  {[expr {2.1*$sz}]} \
                    panel.info.osd_w  {[expr {7*$sz}]} \
                    panel.scope.osd_x {[expr {7.2*$sz}]} \
                    panel.scope.osd_y {[expr {0.1*$sz}]} \
                    panel.scope.osd_w {[expr {7*$sz}]} \
                    panel.z80.osd_x   {[expr {7.2*$sz}]} \
                    panel.z80.osd_y   {[expr {1.1*$sz}]} \
                    panel.z80.osd_w   {[expr {7*$sz}]} \
                    panel.auto_scan.osd_x {[expr {7.2*$sz}]} \
                    panel.auto_scan.osd_y {[expr {2.1*$sz}]} \
                    panel.auto_scan.osd_w {[expr {7*$sz}]} \
                    panel.reset.osd_x {[expr {14.3*$sz}]} \
                    panel.reset.osd_y {[expr {0.1*$sz}]} \
                    panel.reset.osd_w {[expr {7*$sz}]} \
                    panel.pause.osd_x {[expr {14.3*$sz}]} \
                    panel.pause.osd_y {[expr {1.1*$sz}]} \
                    panel.pause.osd_w {[expr {7*$sz}]} \
                    panel.sort.choices [list \
                        "sort: time/call\u25BC" "sort: time/call\u25B2" \
                        "sort: time/vdp\u25BC" "sort: time/vdp\u25B2" \
                        "sort: name\u25BC" "sort: name\u25B2" \
                        "sort: address\u25BC" "sort: address\u25B2"] \
                    panel.sort.selected "sort: time/call\u25BC" \
                    panel.sort.text.osd_text "sort: time/call\u25BC" \
                    panel.bar.choices [list \
                        "bar: time/call" "bar: time/vdp" \
                    panel.bar.selected "bar: time/call" ]\
                    panel.bar.text.osd_text "bar: time/call" \
                    panel.info.choices [list \
                        "info: time/call" "info: time/vdp" \
                        "info: address" ] \
                    panel.info.selected "info: time/call" \
                    panel.info.text.osd_text "info: time/call" \
                    panel.scope.choices [list \
                        "scope: 1s"  "scope: 5s" \
                        "scope: 30s" "scope: 120s" ]\
                    panel.scope.selected "scope: 1s" \
                    panel.scope.text.osd_text "scope: 1s" \
                    panel.z80.textOn  "z80 interface: on" \
                    panel.z80.textOff "z80 interface: off" \
                    panel.auto_scan.textOn  "Auto scan: on" \
                    panel.auto_scan.textOff "Auto scan: off" \
                    panel.reset.text.osd_text "Reset" \
                    panel.pause.textOn  "Resume" \
                    panel.pause.textOff "Pause" \
                    {*}args
                    
            }          

            proc last_detected_tags_window {path args} {
            
                ::wm::widget add $path docked_window
                
            
                ::wm::widget rset $path \
                    title.text.osd_text "Main Detected Tags" \
                    panel.on_upkeep { apply { {} { namespace eval ::wm::widget_methods {
                        
                        if {[rexists skip]} {
                            set skip [expr {[rget skip]-1}]
                            if {$skip>0} {
                                rset skip $skip
                            } else {
                                runset skip
                            }
                            return
                        }
                        rset skip 4
                        
                        
                        dict with ::wm::Configuration {}
                        namespace upvar ::profiler::core Status Status
                        set tag_ids [dict keys [dict get $Status Tags]]
                        
                        set current_ts [machine_info time]
                        set tag_widths [list]
                        foreach tag_id $tag_ids {
                            if {[dict get $Status Tags $tag_id profiler_level]>1} {
                                if {[dict get $Status Tags $tag_id previous_ts_end] > $current_ts-5} {
                                    lappend tag_widths $tag_id [expr {[dict get $::profiler::core::Status Tags $tag_id avg_duration]/[::profiler::gui::util::vdp::get_frame_duration]}]
                                }
                            }
                        }

                        if {![rexists active_tags]} {rset active_tags [dict create]}                            
                        set active_tags [rget active_tags]

                        set idx 0
                        foreach {tag_id width} [lsort -real -decreasing -stride 2 -index 1 $tag_widths] {
                            
                            dict incr active_tags $tag_id
                            if {[dict get $active_tags $tag_id]==1} {
                                dict incr active_tags $tag_id
                                ::wm::widget add [p].$tag_id ::profiler::gui::widgets::tag_bar $tag_id \
                                    bar.osd_rgba [::profiler::gui::util::get_tag_rgba $tag_id]        

                                rset $tag_id.osd_y [expr {$idx*$sz}]
                            }
                            rset $tag_id.osd_y_autoupdate [expr {$idx*$sz}]
                            rset $tag_id.bar.osd_relw [::profiler::gui::util::clamp01 $width]
                            incr idx
                            if {$idx>10} { break }
                        }

                        dict for {tag_id val} $active_tags {
                            
                            dict incr active_tags $tag_id -1

                            if {$val==1} {
                                dict unset active_tags $tag_id
                                ::wm::widget remove [p].$tag_id
                            }
                        }
                        
                        rset active_tags $active_tags
                        if {$idx==0} {set idx 1}
                        rset osd_h [expr {$idx*$sz}]
                    }}}} \
                    {*}$args
                    
            }

            proc info_window_docked {path args} {
            
                ::wm::widget add $path docked_window
                ::wm::widget add $path.panel.text text
                
                ::wm::widget rset $path \
                    title.text.osd_text "Info window" \
                    panel.osd_h {[expr {15*$sz}]} \
                    panel.text.osd_text "" \
                    panel.text.osd_font {$font_mono} \
                    panel.text.osd_x {[expr {1.5*$sz/6.}]} \
                    panel.text.osd_y {[expr {-0.0*$sz/6.}]} \
                    panel.text.osd_size {[expr {45*$sz/60}]} \
                    panel.text.osd_rgba {0xC0C0C0FF} \
                    panel.text.on_upkeep { apply { {} { namespace eval ::wm::widget_methods {
                        
                        if {[rexists skip]} {
                            set skip [expr {[rget skip]-1}]
                            if {$skip>0} {
                                rset skip $skip
                            } else {
                                runset skip
                            }
                            return
                        }
                        rset skip 4
                        
                        if {![dict exist $::profiler::core::Status selected_tag]} {
                            rset osd_text ""
                            return
                        }
                        set tag_id [dict get $::profiler::core::Status selected_tag]
                        if {![dict exist $::profiler::core::Status Tags $tag_id]} {
                            rset osd_text ""
                            return
                        }

                        dict with ::profiler::core::Status Tags $tag_id {
                   
                        proc show {type val} {
                            
                            if {$type=="int"} {
                                if {abs($val)<1000} {
                                    return [format "%4d " $val]
                                }
                                foreach postfix [list "K M G P"] {
                                    set $val [expr {$val/1000}]
                                    if {abs($val)<10} {
                                        return [format "%5.2f$postfix" $val]
                                    } elseif {abs($val)<100} {
                                            return [format "%5.1f$postfix" $val]
                                    } elseif {abs($val)<1000} {
                                            return [format "%5.0f$postfix" $val]
                                    }
                                }
                            }
                            
                            if {$type=="times"} {
                                
                                set cpu [get_active_cpu]
                                set vdp_percent [expr {100 * $val / [::profiler::gui::util::vdp::get_frame_duration]}]
                                if {$vdp_percent>110} {
                                    return [format "%5.3f ms, %5.1f%% of VDP" \
                                        [expr {1000*$val}] \
                                        $vdp_percent \
                                    ]
                                } elseif {$vdp_percent>10} {
                                    return [format "%5.3f ms, %5.1f lines, %5.2f%% of VDP" \
                                        [expr {1000*$val}] \
                                        [expr {$val * 3579545 / 228}] \
                                        $vdp_percent \
                                    ]                                    
                                } else {
                                    return [format "%5.3f ms, %5d T, %5.1f lines, %5.3f%% of VDP" \
                                        [expr {1000*$val}] \
                                        [expr {round($val * [machine_info ${cpu}_freq])}] \
                                        [expr {$val * 3579545 / 228}] \
                                        $vdp_percent \
                                    ]                                    
                                }
                            }
                            return $val
                        }
                            
                        rset osd_text \
"ID: $tag_id
start address: 
invocation count: [show int $count] 

duration:
avg: [show times $avg_duration]
max: [show times $max_duration]

time_between_invocations:
avg: [show times $avg_time_between_invocations]
max: [show times $max_time_between_invocations]

occupation:
avg: [format %5.1f%% [expr {100*$avg_occupation}]]
max: [format %5.1f%% [expr {100*$max_occupation}]]
"
                        }
                    }}}} \
                    {*}$args
                    
            }    

            proc timeline_window_docked {path args} {
            
                ::wm::widget add $path docked_window
                ::wm::widget add $path.panel.timeline rectangle                        
                
                ::wm::widget rset $path \
                    title.text.osd_text "Timeline" \
                    on_upkeep { apply { {} { namespace eval ::wm::widget_methods {
                        
                        if {[rexists skip]} {
                            set skip [expr {[rget skip]-1}]
                            if {$skip>0} {
                                rset skip $skip
                            } else {
                                runset skip
                            }
                            return
                        }
                        rset skip 4
                        
                        if {![dict exist $::profiler::core::Status selected_tag]} {
                            return
                        }
                        set tag_id [dict get $::profiler::core::Status selected_tag]
                        if {![dict exist $::profiler::core::Status Tags $tag_id]} {
                            return
                        }
                        
                        set log [dict get $::profiler::core::Status Tags $tag_id previous_log]
                        if {[dict size $log]==0} {return}
                        
                        lassign [dict keys $log] first_key
                        if {[rget current_timeline_id]==$first_key} { return }
                        rset current_timeline_id $first_key
                        
                        set path [p]

                        ::wm::widget remove $path.panel.timeline
                        
                        ::wm::widget add $path.panel.timeline rectangle \
                            osd_relw 1 \
                            osd_relh 1 

                        ::wm::widget add $path.panel.timeline.cpu rectangle \
                            osd_relw 1 \
                            osd_h {[expr {1.5*$sz}]} \
                            osd_y {[expr {0.25*$sz}]}
                            
                        ::wm::widget add $path.panel.timeline.vpu rectangle \
                            osd_relw 1 \
                            osd_h {[expr {1.5*$sz}]} \
                            osd_y {[expr {2.0*$sz}]}

                        ::wm::widget add $path.panel.timeline.breakdown rectangle \
                            osd_relw 1 \
                            osd_y {[expr {3.75*$sz}]}

                        set subtag_usage [dict create]
                        set subtag_begin [dict create]
                        dict for {idx entry} $log {

                            lassign $entry sub_tag_id sub_ts_begin sub_ts_end

                            #dict incr subtag_usage $sub_tag_id [expr {$sub_ts_end-$sub_ts_begin}] 

                            if {![dict exists $subtag_begin $sub_tag_id]} {
                                dict set subtag_begin $sub_tag_id $sub_ts_begin 
                            }
                        }
                        
                        set subtag_paths [dict create]
                        foreach {sub_tag_id sub_tag_begin} [lsort -real -stride 2 -index 1 $subtag_begin] {

                            set level [dict size $subtag_paths]
                            set subtag_path [format "tag%03d" $level]
                            dict set subtag_paths $sub_tag_id $subtag_path
                            ::wm::widget add $path.panel.timeline.breakdown.$subtag_path ::profiler::gui::widgets::tag_bar $sub_tag_id \
                                osd_y [expr {$level*$sz}] 

                            ::wm::widget add $path.panel.timeline.cpu.$subtag_path rectangle \
                                osd_relw 1 osd_relh 1 osd_rgba 0x00000000
                                
                        }
                        ::wm::widget rset $path.panel.timeline.breakdown \
                            osd_h [expr {[dict size $subtag_paths]*$sz}] 
                        ::wm::widget rset $path.panel \
                            osd_h [expr {(3.75+[dict size $subtag_paths])*$sz}] 
                        
                            
                        set ts_begin [dict get $::profiler::core::Status Tags $tag_id previous_ts_begin]
                        set ts_end   [dict get $::profiler::core::Status Tags $tag_id previous_ts_end]
                        set duration [dict get $::profiler::core::Status Tags $tag_id previous_duration]
                        
                        set idx_id 0
                        puts stderr "[dict size $log] [dict size $subtag_paths]"
                        if ([dict size $log]>200) {return}
                        if ([dict size $subtag_paths]>20) {return}
                        dict for {idx entry} $log {

                            lassign $entry sub_tag_id sub_ts_begin sub_ts_end

                            #puts stderr "$ts_begin $ts_end $duration $sub_ts_end $sub_ts_begin"
                            
                            set pos   [::profiler::gui::util::clamp01 [expr {($sub_ts_begin - $ts_begin)/$duration}]]
                            set width [::profiler::gui::util::clamp01 [expr {($sub_ts_end - $sub_ts_begin)/$duration}]]
                            if {$width<0.01} {set width 0.01}
                            
                            puts stderr "[expr {($sub_ts_begin - $ts_begin)/$duration}] [expr {($sub_ts_end - $sub_ts_begin)/$duration}]"


                            incr idx_id
                            ::wm::widget add $path.panel.timeline.cpu.[dict get $subtag_paths $sub_tag_id].[format "bar%03d" $idx_id] rectangle \
                                osd_relh 1 \
                                osd_relx $pos \
                                osd_relw $width \
                                osd_rgba [::profiler::gui::util::get_tag_rgba $sub_tag_id]
                                
                            ::wm::widget add $path.panel.timeline.breakdown.[dict get $subtag_paths $sub_tag_id].bar.[format "bar%03d" $idx_id] rectangle \
                                osd_relh 1 \
                                osd_relx $pos \
                                osd_relw $width \
                                osd_rgba [::profiler::gui::util::get_tag_rgba $sub_tag_id]                            
                            
                        }
                    }}}} \
                    {*}$args
                    
            }
            
            
            proc tag_bar {path tag_id args} {
                
                ::wm::widget add $path rectangle
                ::wm::widget add $path.bar rectangle
                ::wm::widget add $path.tag_id text
                
                ::wm::widget add $path.favorite button
                ::wm::widget add $path.selected button

                ::wm::widget rset $path \
                    tag_id $tag_id \
                    rgba [::profiler::gui::util::get_tag_rgba $tag_id] \
                    osd_relw 1.0 \
                    osd_relx 0.99 \
                    osd_relx_autoupdate 0.0 \
                    osd_y {[expr {-2*$sz}]} \
                    osd_h {$sz} \
                    osd_clip true \
                    osd_rgba 0x00000080 \
                    tag_id.osd_font {$font_mono} \
                    tag_id.osd_x {[expr {2.25*$sz}]} \
                    tag_id.osd_y {[expr {0.25*$sz/6.}]} \
                    tag_id.osd_size {[expr {5*$sz/6}]} \
                    tag_id.osd_rgba {0xC0C0C0FF} \
                    tag_id.osd_text $tag_id \
                    bar.osd_relh 1 \
                    bar.osd_relw 1 \
                    favorite.osd_w {[expr {1*$sz}]} \
                    favorite.osd_h {[expr {1*$sz}]} \
                    favorite.osd_rgba 0xFFFFFF00 \
                    favorite.osd_borderrgba 0xFFFFFF00 \
                    favorite.text.osd_x {[expr  0.01*$sz]} \
                    favorite.text.osd_y {[expr  -0.1*$sz]} \
                    favorite.text.osd_text {[expr {[dict exist $::profiler::core::Configuration favorite_tags [rget parent.parent.tag_id]]?"\u2605":"\u2606"}]} \
                    favorite.text.osd_size {[expr $sz]} \
                    favorite.text.osd_font {$font_sans} \
                    favorite.text.osd_rgba {0xffffffff} \
                    favorite.on_mouse_button1_down { rset osd_rgba 0xFFFFFF40 } \
                    favorite.on_mouse_button1_up   { rset osd_rgba 0xFFFFFF00 } \
                    favorite.on_activation {
                        if {[dict exist $::profiler::core::Configuration favorite_tags [rget parent.tag_id]]} {
                            dict unset ::profiler::core::Configuration favorite_tags [rget parent.tag_id]
                        } else {
                            dict set ::profiler::core::Configuration favorite_tags [rget parent.tag_id] 1
                        }
                        ::wm::widget request_osd_refresh_recursive "wm" {}
                    }\
                    selected.osd_x {[expr {1*$sz}]} \
                    selected.osd_w {[expr {1*$sz}]} \
                    selected.osd_h {[expr {1*$sz}]} \
                    selected.osd_rgba 0xFFFFFF00 \
                    selected.osd_borderrgba 0xFFFFFF00 \
                    selected.text.osd_x {[expr  0.0*$sz]} \
                    selected.text.osd_y {[expr  -0.2*$sz]} \
                    selected.text.osd_text {[expr {[dict get $::profiler::core::Status selected_tag]==[rget parent.parent.tag_id]?"\u25C9":"\u25CE"}]} \
                    selected.text.osd_size {[expr $sz]} \
                    selected.text.osd_font {$font_sans} \
                    selected.text.osd_rgba {0xffffffff} \
                    selected.on_mouse_button1_down { rset osd_rgba 0xFFFFFF40 } \
                    selected.on_mouse_button1_up   { rset osd_rgba 0xFFFFFF00 } \
                    selected.on_activation {
                        dict set ::profiler::core::Status selected_tag [rget parent.tag_id]
                        dict set ::profiler::core::Configuration favorite_tags [rget parent.tag_id] 1
                        ::wm::widget request_osd_refresh_recursive "wm" {}
                    }\
                    {*}$args
            }
        }
    }
}

namespace import profiler::*
