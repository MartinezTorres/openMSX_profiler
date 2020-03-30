

namespace eval window_manager {

    if ![info exists Status] { variable Status [dict create] }
    if ![info exists Configuration] { variable Configuration [dict create] }
    
    namespace eval widgets {
        
        proc add {widget_type widget_id args} {
            
            if {($widget_type != "rectangle") && ($widget_type != "text")} {
                
                types::${widget_type} $widget_id {*}args
                return
            }

            set widget [dict create \
                activated 0 \
            ]

            foreach {arg value} $args {
                if {[string index $arg 0]== "-"} {
                    set arg [string range $arg 1 end]
                    if {![dict exists $arg ::window_manager::Configuration]} {
                        dict set widget $arg $value
                    } else {
                        error "Widget argument: $arg conflicts with Configuration parameter"
                    }
                } else { 
                    error "Invalid widget argument: $arg"
                }
            }
            
            osd create $widget_type $widget_id
            
            dict set ::profile::gui::core::Status active_configuration [dict create]
                                 
            dict set ::profile::gui::core::Status widgets $widget_id $widget
        }
        
        namespace eval types {
        
            proc add_dock {widget_id args} {
                
                add rectangle $widget_id \
                    -osd_setup {-w $w -relh 1 -rgba 0x00000000} \
                    {*}$args
                
                #add resize_button profile "\u25BA" "\u25C4" {
                #    set w [dict get $config width]
                #    set h [dict get $config height]
                #    osd configure profile -x [expr {0.6*[osd info profile -x]+0.4*(-$w+$h)}] 
                #} { 
                #    osd configure profile -x [expr {0.6*[osd info profile -x]+0.4*0}] 
                #}
            }
            
            proc add_button {widget_id args} {

                add rectangle $widget_id \
                    -text "Button" \
                    -osd_setup   { -relx 1.0 -w [expr -1*$h] -h $h -bordersize [expr 0.1*$h] -borderrgba 0x000000FF -rgba 0x808080FF} \
                    -osd_press   { -rgba 0xC0C0C0FF } \
                    -osd_release { -rgba 0x808080FF } \
                    {*}$args
                
                add text $widget_id.text \
                    -osd_setup {
                        -x [expr 1.5*$h/6.-$h] -y [expr -0.25*$h/6.] 
                        -size [expr 5*$h/6] 
                        -rgba 0x000000FF 
                        -font $font_mono 
                        -text $text
                    }
            }

            proc add_toggle_button {widget_id args} {
                
                add button $widget_id \
                    -is_toggled 0 \
                    -textOn "On" \
                    -textOff "Off" \
                    -on_On {} \
                    -on_Off {} \
                    -osd_On {} \
                    -osd_Off {} \
                    -on_activation { 
                        if {$is_toggled} {
                            set is_toggled 0
                            osd configure $widget_id.text -text $textOff
                            eval $on_Off
                            osd configure $widget_id {*}[subst $osd_Off]
                        } else {
                            set is_toggled 1
                            osd configure $widget_id.text -text $textOn
                            eval $on_On
                            osd configure $widget_id {*}[subst $osd_On]
                        }
                    } \
                    -on_upkeep_On {} \
                    -on_upkeep_Off {} \
                    -osd_upkeep_On {} \
                    -osd_upkeep_Off {} \
                    -on_upkeep  { 
                        if {$is_toggled} {
                            eval $on_upkeep_On
                            osd configure $widget_id {*}[subst $osd_upkeep_On]                        
                        } else {
                            eval $on_upkeep_Off
                            osd configure $widget_id {*}[subst $osd_upkeep_Off]
                        }
                    }
                    {*}$args
            }

            proc add_resize_button {widget_id args} {
                
                add toggle_button $widget_id \
                    {*}$args
            }
        }
    }
    

    namespace eval callbacks {

        namespace eval util {
            
            namespace upvar ::profile::gui::core Status GuiStatus
            proc callback {widget_id callback_id} {
                
                namespace upvar ::profile::gui::core Status GuiStatus
                
                dict with ::profile::gui::core::Configuration {
                    
                    set w $width
                    set h $height
                    
                    if {[dict exists $GuiStatus widgets $widget_id "on_$callback_id"]} {
                        dict with GuiStatus widgets $widget_id {
                            eval [dict get $GuiStatus widgets $widget_id "on_$callback_id"] 
                        }
                    }
                    if {[dict exists $GuiStatus widgets $widget_id "osd_$callback_id"]} {
                        dict with GuiStatus widgets $widget_id {
                            osd configure $widget_id {*}[subst [dict get $GuiStatus widgets $widget_id "osd_$callback_id"]]
                        }
                    }                        
                }
            }
        }

        proc upkeep {} {

            namespace upvar ::profile::gui::core Status GuiStatus
            if {![osd exists profile]} return
            
            if {[dict get $GuiStatus active_configuration] != $::profile::gui::core::Configuration} {
                
                dict set GuiStatus active_configuration $::profile::gui::core::Configuration
                                    
                dict for {widget_id widget} [dict get $GuiStatus widgets] {
                    util::callback $widget_id setup
                }
            }
            
            
            dict for {widget_id widget} [dict get $GuiStatus widgets] {
                util::callback $widget_id upkeep
            }

            after "20" profile::gui::core::wm::upkeep
            return
        }

        proc on_mouse_button1_down {} {
            
            namespace upvar ::profile::gui::core Status GuiStatus
            if {![osd exists profile]} return

            dict for {widget_id widget} [dict get $GuiStatus widgets] {
                if {[is_mouse_over $widget_id]} {
                    dict set GuiStatus widgets $widget_id activated 1
                    util::callback $widget_id press
                }
            }
            after "mouse button1 down" ::profile::gui::core::wm::on_mouse_button1_down
        }

        proc on_mouse_button1_up {} {
            
            namespace upvar ::profile::gui::core Status GuiStatus
            if {![osd exists profile]} return

            dict for {widget_id widget} [dict get $GuiStatus widgets] {

                if {[is_mouse_over $widget_id] && [dict get $GuiStatus widgets $widget_id activated]} {
                    util::callback $widget_id activation
                }
                dict set GuiStatus widgets $widget_id activated 0
                util::callback $widget_id release
            }
            after "mouse button1 up" ::profile::gui::core::wm::on_mouse_button1_up
        }

        proc on_mouse_motion {} {
            
            namespace upvar ::profile::gui::core Status GuiStatus
            if {![osd exists profile]} return

            dict for {widget_id widget} [dict get $GuiStatus widgets] {
                if {[is_mouse_over $widget_id]} {
                    util::callback $widget_id hover
                }
            }
            after "mouse motion" ::profile::gui::core::wm::on_mouse_motion
       }

        proc is_mouse_over {widget} {
            
            if {[osd exists $widget]} {
                catch {
                    lassign [osd info $widget -mousecoord] x y
                    if {($x >= 0) && ($x <= 1) && ($y >= 0) && ($y <= 1)} {
                        return 1
                    }
                }
            }
            return 0
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
            profile.all.ordering [dict create] \
            profile.favorite.ordering [dict create] \
        ]}
    }


}
