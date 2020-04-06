
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
            ]}

            proc Configuration {} { return [dict create \
                auto_scan 0 \
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

                    if {$profiler_level < 2 && $ts_end-$ts_begin < 0.0020} { 

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
            ::wm::widget add "wm.profiler.dock.panel.all_tags" ::profiler::gui::widgets::all_tag_window 
        }
        
        namespace eval widgets {

            proc control_window {path args} {
            
                ::wm::widget add $path docked_window  \
                    title.text.osd_text "Controls"
            }          

            proc all_tag_window {path args} {
            
                ::wm::widget add $path docked_window \
                    title.text.osd_text "All Detected Tags"
            }          
        }
    }




    if {0} {
    namespace eval gui {
        
        namespace eval core {
            
            if ![info exists Status] { variable Status [dict create] }
            if ![info exists Configuration] { variable Configuration [dict create] }


            proc stop {} {
                
                if {[osd exists "profiler"]} {
                    osd destroy profiler
                }
                set ::profiler::gui::core::Status [dict create]
                return
            }

            proc resetConfiguration {} {
                
                set ::profiler::gui::core::Configuration [defaults::Configuration]
                return
            }

            namespace eval wm {

                if ![info exists Status] { variable Status [dict create] }
                if ![info exists Configuration] { variable Configuration [dict create] }
                
                namespace eval widgets {
                    
                    proc add {widget_type widget_id args} {
                        
                        if {$widget_type == "dock"} { return [add_dock $widget_id {*}args] }
                        if {$widget_type == "resize_button"} { return [add_resize_button $widget_id {*}args] }
                        
                        set widget [dict create \
                            activated 0 \
                        ]

                        foreach {arg value} $args {
                            dict set widget $arg $value
                        }
                        
                        osd create $widget_type $widget_id
                        
                        dict set ::profiler::gui::core::Status active_configuration [dict create]
                                             
                        dict set ::profiler::gui::core::Status widgets $widget_id $widget
                    }
                    
                    proc add_dock {widget_id args} {
                        
                        add rectangle $widget_id \
                            -osd_setup {-w $w -relh 1 -rgba 0x00000000} \
                            {*}$args
                        
                        #add resize_button profiler "\u25BA" "\u25C4" {
                        #    set w [dict get $config width]
                        #    set h [dict get $config height]
                        #    osd configure profiler -x [expr {0.6*[osd info profiler -x]+0.4*(-$w+$h)}] 
                        #} { 
                        #    osd configure profiler -x [expr {0.6*[osd info profiler -x]+0.4*0}] 
                        #}
                    }
                    
                    proc add_toggle_button {parent icon1 icon2 upkeep1 upkeep2 args} {
                        
                        add rectangle $widget_id \
                            -is_toggled 0 \
                            -text0 $text0 \
                            -text1 $text1 \
                            -osd_setup   { -relx 1.0 -w [expr -1*$h] -h $h -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF} \
                            -osd_press   { -rgba 0xC0C0C0FF } \
                            -osd_release { -rgba 0x808080FF } \
                            -on_activation "eval {
                                if { \[osd info $parent.scroll.text -text] == \"$icon1\" } {
                                    osd configure $parent.scroll.text -text \"$icon2\"
                                } else {
                                    osd configure $parent.scroll.text -text \"$icon1\"
                                }
                            }"
                            -on_upkeep "eval {
                                set parent $parent
                                variable config
                                if { \[osd info $parent.scroll.text -text] == \"$icon1\" } {
                                    $upkeep1
                                } else {
                                    $upkeep2
                                }
                            }"
                            -on_hover "$parent Scroll Button"
                            {*}$args
                        
                        add text $widget_id.text -on_setup {
                            -x [expr 1.5*$height/6.-$height] -y [expr -0.25*$height/6.] -size [expr 5*$height/6] -rgba 0x000000FF
                            -font $font_mono -text $icon2
                        }
                    }
                    
                    proc add_resize_button {parent icon1 icon2 upkeep1 upkeep2 args} {
                        
                        add rectangle $widget_id \
                            -osd_setup { -relx 1.0 -w [expr -1*$h] -h $h -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF} \
                            -osd_press { -rgba 0xC0C0C0FF } \
                            -osd_release { -rgba 0x808080FF } \
                            -on_activation "eval {
                                if { \[osd info $parent.scroll.text -text] == \"$icon1\" } {
                                    osd configure $parent.scroll.text -text \"$icon2\"
                                } else {
                                    osd configure $parent.scroll.text -text \"$icon1\"
                                }
                            }"
                            -on_upkeep "eval {
                                set parent $parent
                                variable config
                                if { \[osd info $parent.scroll.text -text] == \"$icon1\" } {
                                    $upkeep1
                                } else {
                                    $upkeep2
                                }
                            }"
                            -on_hover "$parent Scroll Button"
                            {*}$args
                        
                        add text $widget_id.text -on_setup {
                            -x [expr 1.5*$height/6.-$height] -y [expr -0.25*$height/6.] -size [expr 5*$height/6] -rgba 0x000000FF
                            -font $font_mono -text $icon2
                        }
                    }
                }
                
        }

            namespace eval defaults {

                proc Status {} { return [dict create \
                    widgets [dict create] \
                    active_configuration [dict create] \
                ]}

                proc Configuration {} { return [dict create \
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
                    profiler.all.ordering [dict create] \
                    profiler.favorite.ordering [dict create] \
                ]}
            }

            
            
            if 0 {

            namespace eval widgets {
                
                namespace eval dock {
                    
                    #
                    # Main profilerr Window
                    #
                    osd create rectangle profiler -x 0 -y 20 -w $w -relh 1 -scaled true -clip true -rgba 0x00000000
                    after "mouse button1 down" [namespace code gui_on_mouse_button1_down]


                    
                }

                namespace eval window {



                }

                namespace eval scrollbox {
                }

                namespace eval tag_bar {
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
                }
                
                namespace eval button {
                    
    #                        osd configure profiler.config.info.text -text [dict get $config buttons $widget help]
    # dict set config current_help_widget $widget
                }

            }
            
            namespace eval windows {
                
                namespace eval configuration {
                # Config Buttons
                proc add_config_button {name x y text on_pressed help} {
                    
                    variable config
                    
                    set w [dict get $config width]
                    set h [dict get $config height]
                    
                    osd create rectangle profiler.config.$name  -x [expr $x*$w/4.] -y [expr ($y+1)*$h] -w [expr $w/4-0.1*$h] -h [expr 0.9*$h] -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF
                    osd create text      profiler.config.$name.text -x [expr 1.5*$h/6.] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xFFFFFFFF \
                        -font [dict get $config font_sans] -text [eval $text]

                    gui_add_button profiler.config.$name \
                        "eval { osd configure profiler.config.$name -rgba 0xC0C0C0FF } " \
                        "eval { osd configure profiler.config.$name -rgba 0x808080FF } " \
                        "eval { $on_pressed }" \
                        "" \
                        "$help"
                }

                osd create rectangle profiler.config -y $h -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
                osd create text      profiler.config.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                    -text "Configuration"

                add_scroll_button profiler.config "\u25BC" "\u25B2" {
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
                    osd destroy profiler
                    gui_create
                } "Toggles text Size between 5, 6, and 7"

                osd create rectangle profiler.config.info  -x [expr 0*$w/4.] -y [expr (2+1)*$h] -w [expr $w-0.1*$h] -h [expr 1.9*$h] -rgba 0x40404080
                osd create text      profiler.config.info.text -x [expr 1.5*$h/6.] -y [expr 0.5*$h/6.] -size [expr 4*$h/6] -rgba 0xC0C0C0FF \
                        -font [dict get $config font_sans] -text "Command Info"

                }
                
                namespace eval all_tags {

                osd create rectangle profiler.all -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
                osd create text      profiler.all.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                    -text "All Tags"

                add_scroll_button profiler.all "\u25BC" "\u25B2" {
                    osd configure profiler.all -y [expr {[osd info profiler.config -y] + [osd info profiler.config -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
                } { 
                    osd configure $parent -y [expr {[osd info profiler.config -y] + [osd info profiler.config -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*(1+[dict get $config num_sections])*[dict get $config height]}]
                }

                }
                
                namespace eval favorite_tags {

                osd create rectangle profiler.favorite -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
                osd create text      profiler.favorite.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                    -text "Favorite Tags"

                add_scroll_button profiler.favorite "\u25BC" "\u25B2" {
                    osd configure $parent -y [expr {[osd info profiler.all -y] + [osd info profiler.all -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
                } { 
                    osd configure $parent -y [expr {[osd info profiler.all -y] + [osd info profiler.all -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*(1+[dict get $config num_favorite_sections])*[dict get $config height]}]
                }

                }
                
                namespace eval timeline {
                osd create rectangle profiler.detailed -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
                osd create text      profiler.detailed.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                    -text "Usage and Timeline:"

                add_scroll_button profiler.detailed "\u25BC" "\u25B2" {
                    osd configure $parent -y [expr {[osd info profiler.info -y] + [osd info profiler.info -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
                } { 
                    osd configure $parent -y [expr {[osd info profiler.info -y] + [osd info profiler.info -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*(5+[dict get $config num_sections_in_usage])*[dict get $config height]}]
                }
                
                osd create rectangle profiler.detailed.timeline_cpu -y [expr 1.*$h] -w $w -h [expr 2.*$h] -clip true
                osd create rectangle profiler.detailed.timeline_vdp -y [expr 3.*$h] -w $w -h [expr 2.*$h] -clip true
                osd create rectangle profiler.detailed.usage -y [expr 5.*$h] -w $w -relh 1 -clip true -rgba 0x00000088        
                }
                
                namespace eval details {
                osd create rectangle profiler.info -w $w -h [expr 1*$h] -clip true -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x00000088
                osd create text      profiler.info.text -x 0 -y [expr 0.5*$h/6] -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                    -text "Information:"

                add_scroll_button profiler.info "\u25BC" "\u25B2" {
                    osd configure $parent -y [expr {[osd info profiler.favorite -y] + [osd info profiler.favorite -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*[dict get $config height]}]
                } { 
                    osd configure $parent -y [expr {[osd info profiler.favorite -y] + [osd info profiler.favorite -h]}]                
                    osd configure $parent -h [expr {0.6*[osd info $parent -h]+0.4*5*[dict get $config height]}]
                }
                
       proc gui_update_details {id} {
                
                variable config
                variable sections

                set w [dict get $config width]
                set h [dict get $config height]
                osd destroy profiler.detailed.timeline_cpu
                osd destroy profiler.detailed.timeline_vdp
                osd destroy profiler.detailed.usage

                foreach button [dict keys [dict get $config buttons] profiler.detailed.{*}] { dict unset config buttons $button }

                osd create rectangle profiler.detailed.timeline_cpu -y [expr 1.*$h] -w $w -h [expr 2.*$h] -clip true
                osd create rectangle profiler.detailed.timeline_vdp -y [expr 3.*$h] -w $w -h [expr 2.*$h] -clip true
                osd create rectangle profiler.detailed.usage -y [expr 5.*$h] -w $w -relh 1 -clip true -rgba 0x00000088       
                if {[dict exists $sections $id]} {
                    
                    osd configure profiler.detailed.text -text [format "Usage and Timeline: %s" $id]
                    osd configure profiler.info.text -text [format "Information: %s" $id]
                    

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
                                set timeline_bar_name [format "profiler.detailed.timeline_cpu.bar%03d" $idx]
                                osd create rectangle $timeline_bar_name -x 0 -y 0 -w 0 -h [expr 2*$h] -rgba [gui_get_color $sub_id]
                                puts stderr [format "w: %s %s %s %s" $ts_end $ts_begin $td_parent ($ts_end-$ts_begin)]
                                osd configure $timeline_bar_name -x [expr $w*($ts_begin-$ts_begin_parent)/$td_parent]
                                osd configure $timeline_bar_name -w [expr $w*($ts_end-$ts_begin)/$td_parent]

                                set usage_bar_name [format "profiler.detailed.usage.bar%03d" $idx]
                                osd create rectangle $usage_bar_name -x 0 -y [expr [dict get $subsections $sub_id depth]*$h] -w 0 -h [expr 1*$h] -rgba [gui_get_color $sub_id]
                                osd configure $usage_bar_name -x [expr $w*($ts_begin-$ts_begin_parent)/$td_parent]
                                osd configure $usage_bar_name -w [expr $w*($ts_end-$ts_begin)/$td_parent]
                            }
                        }
                        
                        set idx 0
                        dict for {sub_id subsection}  $subsections {
                            incr idx
                            set usage_text_time [format "profiler.detailed.usage.time%03d" $idx]
                            osd create text $usage_text_time -x [expr 0.125*$h] -y [expr (0.5/6 + [dict get $subsections $sub_id depth])*$h] \
                                -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_mono] \
                                -text [format "T:%s" [gui_to_unit [dict get $subsections $sub_id total_time]]]

                            set usage_text_name [format "profiler.detailed.usage.name%03d" $idx]
                            osd create text $usage_text_name -x [expr 4.125*$h] -y [expr (0.5/6 + [dict get $subsections $sub_id depth])*$h] \
                                -size [expr 4*$h/6] -rgba 0xffffffff -font [dict get $config font_sans] \
                                -text $sub_id
                                
                        }
                        
                    
                        dict set config num_sections_in_usage $depth_level
                    }
                }
            }
                
                    
                }
                
                
            }
            
            namespace eval util {

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

                namespace eval vdp {

                    set_help_text profiler::get_VDP_frame_duration [join {
                        "Usage: profiler::get_VDP_frame_duration\n"
                        "Returns the duration, in seconds, of the VDP frame."
                    } {}]
                    proc get_VDP_frame_duration {} {
                        expr {(1368.0 * (([vdpreg 9] & 2) ? 313 : 262)) / (6 * 3579545)}
                    }

                    set_help_text profiler::get_start_of_VDP_frame_time [join {
                        "Usage: profiler::get_start_of_VDP_frame_time\n"
                        "Returns the time, in seconds, of the start of the VDP last frame."
                    } {}]
                    proc get_start_of_VDP_frame_time {} {
                        expr {[machine_info time] - [machine_info VDP_cycle_in_frame] / (6.0 * 3579545)}
                    }
                    
                    set_help_text profiler::get_time_since_VDP_start [join {
                        "Usage: profiler::get_time_since_VDP_start\n"
                        "Returns the time that has passed, in seconds, since the start of the last VDP start."
                    } {}]
                    proc get_time_since_VDP_start {} {
                        expr {[machine_info VDP_cycle_in_frame] / (6.0 * 3579545)}
                    }   
                }
                


        ########################################################################                

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

                namespace eval color {

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

                    
                }

                namespace help {
                    
                    proc set text {}
                    
                    proc get {}
                }
            }
            

    
            }
        
        }
    
        proc stop  {} { core::stop }
        proc start {} { ::profiler::start; core::start}        
    }

    }
}

namespace import profiler::*
