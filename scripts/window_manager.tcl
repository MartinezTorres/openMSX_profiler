

namespace eval wm {

    if ![info exists Status] { variable Status [dict create] }
    if ![info exists Configuration] { variable Configuration [dict create] }

    proc start {} {

        if {[dict exists $::wm::Status widgets wm]} return
        if {[dict size $::wm::Status]==0} { set ::wm::Status [::wm::defaults::Status] } 
        if {[dict size $::wm::Configuration]==0} { set ::wm::Configuration [::wm::defaults::Configuration] } 
        
        dict set ::wm::Status widgets wm {}
        osd create rectangle "wm" -relw 1 -relh 1 -rgba 0x00000000 -clip true
                
        after "realtime" 0.020 ::wm::callbacks::upkeep
        
        bind -layer osd_wm "mouse button1 down" -event {::wm::callbacks::on_mouse_button1_down}
        bind -layer osd_wm "mouse button1 up"   -event {::wm::callbacks::on_mouse_button1_up}
        bind -layer osd_wm "mouse motion"       -event {::wm::callbacks::on_mouse}
        bind -layer osd_wm "mouse wheel"        -event {::wm::callbacks::on_mouse}
        activate_input_layer osd_wm -blocking
    }

    proc stop {} {
        
        deactivate_input_layer osd_wm
        dict unset ::wm::Status widgets wm
        
    }

    proc reload_configuration {} {
    }
    
    proc widget {command absolute_path args} {
        
        #puts "Widget: $command $absolute_path $args"
        ::wm::start
        if {$absolute_path=={}} { error "absolute_path can not be empty."}
        
        set previous_path $widget_methods::base_path 
        set widget_methods::base_path $absolute_path
        
        if {[namespace which widget_methods::${command}] == {}} {
            error "Unknown widget command: \"$command\""
        }

        set ret [widget_methods::${command} {*}$args]

        set widget_methods::base_path $previous_path
        return $ret
    }
    
    namespace eval widget_methods {
        
        variable base_path {}
        
        # Returns the absolute path. 
        # Key value "parent" actually moves up a level.
        proc get_absolute_path { base_path {relative_path {}} } {
            
            if {$relative_path != {}} {             
                set absolute_path $base_path.$relative_path
            } else {
                set absolute_path $base_path
            }
            
            #puts stderr $absolute_path
            while {[regsub {\.[^\.]*\.parent} $absolute_path {} absolute_path]} {}
            #puts stderr $absolute_path
            return $absolute_path
        }
        
        # Shortcut: returns the absolute path w.r.t. the current widget's path.
        proc p { {relative_path {}} } { return [get_absolute_path $::wm::widget_methods::base_path $relative_path] }

        # Returns value of the argument pointed by the relative id
        proc rexists {relative_path} {

            set absolute_path [p $relative_path]
            return [dict exists $::wm::Status widgets $absolute_path]
        }

        proc rget {relative_path} {
            
            set absolute_path [p $relative_path]
            set ret {}
            catch { set ret [dict get $::wm::Status widgets $absolute_path] }
            return $ret
        }

        proc rsub {relative_path args} {

            set absolute_path [p $relative_path]
            regexp {^(.*)\.([^\.]*)$} $absolute_path match parent parameter
            
            set old_base_path $::wm::widget_methods::base_path
            set ::wm::widget_methods::base_path $parent

            set ret {}
            catch { set ret [dict get $::wm::Status widgets $absolute_path] }

            dict with ::wm::Configuration {}
            set ret [subst $ret]

            set ::wm::widget_methods::base_path $old_base_path
            return $ret
        }

        proc reval {relative_path args} {
            
            if {![rexists $relative_path]} {return}
            

            set absolute_path [p $relative_path]
            regexp {^(.*)\.([^\.]*)$} $absolute_path match parent parameter
            
            set old_base_path $::wm::widget_methods::base_path
            set ::wm::widget_methods::base_path $parent

            dict with ::wm::Configuration {}
            #puts stderr "REVAL: [dict get $::wm::Status widgets $absolute_path]"
            set ret [eval [dict get $::wm::Status widgets $absolute_path]]

            set ::wm::widget_methods::base_path $old_base_path
            return $ret            
        }

        proc rset {args} {
            
            foreach {relative_path value} $args {
                set absolute_path [p $relative_path]
                dict set ::wm::Status widgets $absolute_path $value
                dict set ::wm::Status to_update $absolute_path {}
                #if {[rexists ${relative_path}_on_set]} {puts stderr "TRying $relative_path _on_set" }
                reval ${relative_path}_on_set $value
            }
        }

        proc runset {args} {
            
            foreach relative_path $args {
                set absolute_path [p $relative_path]
                if {[dict exists $::wm::Status widgets $absolute_path]} {
                    dict unset ::wm::Status widgets $absolute_path
                    dict unset ::wm::Status to_update $absolute_path
                }
            }
        }

        proc request_osd_refresh_recursive {relative_path} {
            
            set absolute_path [p $relative_path]
            foreach child_absolute_path [dict keys [dict get $::wm::Status widgets] "$absolute_path.*"] {
                #puts stderr "Updateate cabrn!! $child_absolute_path"
                dict set ::wm::Status to_update $child_absolute_path {}
            }
            
            foreach global_path [dict keys [dict get $::wm::Status to_update]] {
                if {[regexp {^(.*)\.osd_([^\._]*)$} $global_path global_path osd_id parameter]} {
                    #puts stderr "Updating $osd_id $parameter [::wm::widget rsub $global_path {}]"
                    osd configure $osd_id -$parameter [::wm::widget rsub $global_path {}]
                }
            }
            dict set ::wm::Status to_update [dict create]
        }

        proc request_osd_refresh {args} {
            
            foreach relative_path $args {
                set absolute_path [p $relative_path]  
                dict set ::wm::Status to_update $absolute_path {}
            }
        }
        
        proc add {widget_type args} {
            
            ::wm::start
            
            if { [rexists {}]} { error "Adding an already existing widget" }
            if {![rexists parent]} { error "Adding an orfan widget: [p] [p parent]" }

            rset inner_type $widget_type

            if {[namespace which $widget_type] != {}} {
                
                $widget_type [p] {*}$args
                
            } elseif {[namespace which ::wm::widgets::$widget_type] != {}} {
                
                ::wm::widgets::$widget_type [p] {*}$args
                
            } elseif {$widget_type=="text"} {
                
                osd create text [p]
                rset {} {} {*}$args
                
            } elseif {$widget_type=="rectangle"} {

                osd create rectangle [p]
                rset {} {} {*}$args
            
            } else {
                error "Requested an unknown widget type"
            }

            if {![rexists {}]} { error "Widget not created" }
            
            rset outer_type $widget_type
            
            reval parent.on_added_child [string range [p] [expr {[string length [p parent]]+1}] end ]
        }

        proc remove {} {

            set absolute_path [p]
            foreach child_absolute_path [dict keys [dict get $::wm::Status widgets] "$absolute_path*"] {

                dict unset ::wm::Status widgets $child_absolute_path
                dict unset ::wm::Status to_update $child_absolute_path
                if {[osd exists $child_absolute_path]} { 
                    osd destroy $child_absolute_path 
                }
            }
        }

        proc remove_old {} {

            reval on_pre_remove

            set absolute_path [p]
            foreach child_absolute_path [dict keys [dict get $::wm::Status widgets] "$absolute_path*"] {
                if {[regexp {^(.*)\.[^\.]*$} $child_absolute_path match parent]} {
                    if {$parent == $absolute_path} {
                        ::wm::widget remove $child_absolute_path
                    }
                }
            }

            reval on_post_remove
            if {[osd exists $absolute_path]} { 
                osd destroy $absolute_path 
            }
            runset {}
        }
        
        proc rebase {old_path} {
            
            set old_path [get_absolute_path $new_path]
            set new_path [p]

            reval $old_path.on_pre_rebase $new_path
            
            if { [rexists {}]} { error "Rebasing into an already existing widget" }
            if {![rexists parent]} { error "Rebasing into an orfan widget" }
            
            rset {} [dict get $::wm::Status widgets $old_path]
            if {[osd exists $old_path]} { 
                osd create [::wm::widget rexists $old_path inner_type] $new_path
            }
        
            foreach child_absolute_path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.([^\.]*)$} $child_absolute_path match parent children]} {
                    if {$parent == $old_path} {
                        ::wm::widget rebase "$old_path.$children" "$new_path.$children" 
                    }
                }
            }

            reval on_post_rebase.$old_path

            if {[osd exists $old_path]} { osd destroy $old_path }
            dict unset ::wm::Status widgets $old_path
        }
    }

    namespace eval widgets {
                
        proc dock {path args} {
            ::wm::widget add $path rectangle
            ::wm::widget add $path.panel rectangle
            ::wm::widget add $path.title rectangle 
            ::wm::widget add $path.title.text text      
            ::wm::widget add $path.hide toggle_button 

            ::wm::widget rset $path \
                first_window {} \
                last_window {} \
                osd_x {[expr {-10*$sz}]} \
                osd_x_autoupdate 0 \
                osd_y {[expr {4*$sz}]} \
                osd_w {[expr {$sz*$width}]} \
                osd_relh 1 \
                osd_clip true \
                osd_rgba 0x00000040 \
                window_list [dict create] \
                title.osd_x 0 \
                title.osd_y 0 \
                title.osd_w {[expr {($width-1)*$sz}]} \
                title.osd_h {[expr {1*$sz}]} \
                title.osd_rgba {0x404040FF} \
                title.text.osd_text "Dock" \
                title.text.osd_font {$font_sans} \
                title.text.osd_x {[expr {1.5*$sz/6.}]} \
                title.text.osd_y {[expr {0.25*$sz/6.}]} \
                title.text.osd_size {[expr {5*$sz/6}]} \
                title.text.osd_rgba {0x808080FF} \
                panel.on_added_child {
                    lassign $args child
                    puts stderr "AAA: [p] [rget $child.outer_type]"
                    if {[rget $child.outer_type]=="docked_window"} {
                        if {[rget parent.first_window]=={}} {
                            rset parent.first_window $child
                        } else {
                            rset $child.prev_window [rget parent.last_window]
                            rset [rget parent.last_window].next_window $child
                        }
                        rset parent.last_window $child
                    }
                } \
                panel.osd_x 0 \
                panel.osd_y {[expr {1*$sz}]} \
                panel.osd_w {[expr {($width)*$sz}]} \
                panel.osd_relh 1 \
                panel.osd_clip true \
                panel.osd_rgba {0x00000040} \
                hide.textOn  "\u25BA" \
                hide.textOff "\u25C4" \
                hide.on_On  { rset parent.osd_x_autoupdate {[expr {-($width-1)*$sz}]} } \
                hide.on_Off { rset parent.osd_x_autoupdate 0 } \
                hide.osd_relx 1 \
                hide.osd_w {[expr {-1*$sz}]} \
                hide.osd_h {[expr {1*$sz}]} \
                hide.text.osd_x {[expr {1.5*$sz/6.-$sz}]} \
                hide.text.osd_y {[expr {-0.25*$sz/6.}]} \
                hide.text.osd_size {[expr {5*$sz/6}]} \
                hide.text.osd_font {$font_mono} \
                {*}$args

        }

        proc vertical_scroll_bar {path args} {
            
            ::wm::widget add $path rectangle
            ::wm::widget add $path.bar rectangle

            ::wm::widget rset $path \
                visible_range 50.0 \
                total_range 100.0 \
                offset 0.0 \
                offset_start 0.0 \
                total_range_on_set { request_osd_refresh bar.osd_y bar.osd_h } \
                visible_range_on_set { request_osd_refresh bar.osd_y bar.osd_h } \
                offset_on_set { 
                    set offset [rsub offset]
                    if {$offset<0} {rset offset 0.0}
                    if {$offset>[rsub total_range]} {rset offset [rsub total_range]}
                    rset offset_start [expr {
                            [rsub offset]*([rsub total_range]-[rsub visible_range])/[rsub total_range]
                    }]
                    reval on_update
                    request_osd_refresh bar.osd_y bar.osd_h 
                } \
                osd_x 0 \
                osd_y 0 \
                osd_w {[expr {1*$sz}]} \
                osd_h {[expr {1*$sz}]} \
                osd_clip true \
                osd_rgba {0x404040FF} \
                osd_bordersize {[expr {0.1*$sz}]} \
                osd_borderrgba {0x404040FF} \
                bar.osd_x 0 \
                bar.osd_y_on_set { puts stderr "ON_SET: [p] $args [subst $args]" } \
                bar.osd_y {[expr {[rsub parent.offset_start]*[rsub parent.osd_h]/[rsub parent.total_range]}]} \
                bar.osd_w {[expr {1*$sz}]} \
                bar.osd_h_on_set { puts stderr "ON_SET: [p] $args [subst $args]" } \
                bar.osd_h {[expr {[rsub parent.osd_h]*([rsub parent.visible_range]/[rsub parent.total_range])}]} \
                bar.osd_clip true \
                bar.osd_rgba {0x808080FF} \
                bar.osd_bordersize {[expr {0.1*$sz}]} \
                bar.osd_borderrgba {0x808080FF} \
                is_clickable {} \
                on_mouse_button1_down {
                    lassign [osd info [p] -mousecoord] x y
                    
                    set bar_begin [expr {[rsub bar.osd_y]/[rsub osd_h]}]
                    set bar_size  [expr {[rsub bar.osd_h]/[rsub osd_h]}]
                    set bar_end   [expr {$bar_begin+$bar_size}]
                    if {$y<$bar_begin} {
                        rset offset [expr {[rsub offset]-[rsub visible_range]}]
                    } elseif {$y>$bar_end} {    
                        rset offset [expr {[rsub offset]+[rsub visible_range]}]
                    }
                    
                    set bar_begin [expr {[rsub bar.osd_y]/[rsub osd_h]}]
                    set bar_size  [expr {[rsub bar.osd_h]/[rsub osd_h]}]
                    set bar_end   [expr {$bar_begin+$bar_size}]
                    if {($y>$bar_begin) && ($y<$bar_end)} {
                        rset drag_y $y
                        rset on_mouse_motion {
                            lassign [osd info [p] -mousecoord] x y
                            rset offset [expr {[rsub offset]+($y-[rsub drag_y])*[rsub total_range]*([rsub total_range]/([rsub total_range]-[rsub visible_range]))}]
                            rset drag_y $y
                        }    
                    }
                } \
                on_mouse_button1_up {
                    runset drag_y
                    runset on_mouse_motion
                } \
                {*}$args
        }

        proc docked_window {path args} {
            
            ::wm::widget add $path rectangle
            ::wm::widget add $path.panel rectangle
            ::wm::widget add $path.title rectangle 
            ::wm::widget add $path.title.text text      
            ::wm::widget add $path.hide toggle_button
            ::wm::widget add $path.left_scroll_bar vertical_scroll_bar
            ::wm::widget add $path.resize rectangle

            ::wm::widget rset $path \
                osd_x 0 \
                osd_y 0 \
                osd_y_on_set {
                    if {[rexists next_window]} {
                        #puts stderr "Why? [p] rset parent.[rget next_window].osd_y [expr {[subst [rget osd_y]]+[subst [rget osd_h]]}]"
                        rset parent.[rget next_window].osd_y [expr {[rsub osd_y]+[rsub osd_h]}]
                    }
                } \
                osd_w {[expr {$sz*$width}]} \
                osd_h {[expr {1*$sz}]} \
                osd_h_autoupdate {[expr {2*$sz+[rsub visible_height]}]} \
                osd_h_on_set {
                    if {[rexists next_window]} {
                        #puts stderr "osd_h? [p] rset parent.[rget next_window].osd_y [expr {[subst [rget osd_y]]+[subst [rget osd_h]]}]"
                        rset parent.[rget next_window].osd_y [expr {[rsub osd_y]+[rsub osd_h]}]
                    }
                } \
                osd_clip true \
                osd_rgba 0x00000040 \
                title.osd_x 0 \
                title.osd_y 0 \
                title.osd_w {[expr {($width-0.9)*$sz}]} \
                title.osd_h {[expr {1*$sz}]} \
                title.osd_bordersize {[expr {0.1*$sz}]} \
                title.osd_borderrgba {0x404040FF} \
                title.osd_rgba {0x808080FF} \
                title.text.osd_text "Dock" \
                title.text.osd_font {$font_sans} \
                title.text.osd_x {[expr {1.5*$sz/6.}]} \
                title.text.osd_y {[expr {0.25*$sz/6.}]} \
                title.text.osd_size {[expr {5*$sz/6}]} \
                title.text.osd_rgba {0x404040FF} \
                panel.osd_x 0 \
                panel.osd_y {[expr {1*$sz}]} \
                panel.osd_w {[expr {($width-1)*$sz}]} \
                panel.osd_h {[expr {5*$sz}]} \
                panel.osd_h_on_set {
                    request_osd_refresh_recursive parent
                } \
                panel.osd_clip true \
                panel.osd_rgba {0x40404040} \
                hide.textOn  "\u25BC" \
                hide.textOff "\u25B2" \
                hide.on_On  { rset parent.osd_h_autoupdate {[expr {1*$sz}]} } \
                hide.osd_relx 1 \
                hide.osd_w {[expr {-1*$sz}]} \
                hide.osd_h {[expr {1*$sz}]} \
                hide.text.osd_x {[expr {1.5*$sz/6.-$sz}]} \
                hide.text.osd_y {[expr {-0.25*$sz/6.}]} \
                hide.text.osd_size {[expr {5*$sz/6}]} \
                hide.text.osd_font {$font_mono} \
                left_scroll_bar.osd_y {[expr {1*$sz}]} \
                left_scroll_bar.osd_x {[expr {($width-1)*$sz}]} \
                left_scroll_bar.osd_h {[rsub parent.visible_height]} \
                left_scroll_bar.total_range {[expr {1.0*[rsub parent.panel.osd_h]}]} \
                left_scroll_bar.visible_range {[expr {1.0*[rsub parent.visible_height]}]} \
                left_scroll_bar.on_update {
                    rset parent.panel.osd_y [expr {1*$sz-[rsub offset_start]}]
                } \
                resize.osd_y {[expr {[rsub parent.visible_height]+1*$sz}]} \
                resize.osd_x {[expr {($width-1)*$sz}]} \
                resize.osd_w {[expr {1*$sz}]} \
                resize.osd_h {[expr {1*$sz}]} \
                resize.osd_bordersize {[expr {0.1*$sz}]} \
                resize.osd_borderrgba {0x606060FF} \
                resize.osd_rgba {0x606060FF} \
                resize.is_clickable {} \
                resize.on_mouse_button1_down { 
                    
                    rset osd_rgba 0x808080FF 

                    lassign [osd info [p] -mousecoord] x y
                    rset drag_x $x
                    rset drag_y $y
                    
                    
                    rset on_mouse_motion {
                        lassign [osd info [p] -mousecoord] x y
                        
                        set offset_x [expr {($x-[rget drag_x])*[rsub osd_w]}]
                        set offset_y [expr {($y-[rget drag_y])*[rsub osd_h]}]

                        rset parent.visible_height [expr {[rsub parent.visible_height]+$offset_y}]
                        
                        request_osd_refresh_recursive parent.parent
                    }
                } \
                resize.on_mouse_button1_up   { 

                    rset osd_rgba 0x606060FF 
                    runset on_mouse_motion
                } \
                visible_height_on_set {
                    lassign $args value
                    if {[subst $value]<0} {rset visible_height 0}
                    if {[subst $value]>[rsub panel.osd_h]} {rset visible_height [rsub panel.osd_h]}
                    
                    rset hide.on_Off "rset parent.osd_h_autoupdate \{\[expr \{2*\$sz+$value\}\]\}"
                    reval osd_h_on_set
                } \
                visible_height {[expr {3*$sz}]} \
                {*}$args

                
        }

        proc toggle_button {path args} {
            
            ::wm::widget add $path button 
            
            ::wm::widget rset $path \
                is_toggled 0 \
                textOn "On" \
                textOff "Off" \
                on_On {} \
                on_Off {} \
                on_activation { 
                    if {[rget is_toggled]} {
                        rset is_toggled 0
                        puts stderr off[rget on_Off]
                        eval [rget on_Off]
                    } else {
                        rset is_toggled 1
                        puts stderr On[rget on_On]
                        eval [rget on_On]
                    }
                    request_osd_refresh text.osd_text
                } \
                text.osd_text {[expr {[rget parent.is_toggled]?[rget parent.textOn]:[rget parent.textOff]}]} \
                {*}$args
        }

        proc button {path args} {

            ::wm::widget add $path rectangle  
            ::wm::widget add $path.text text 
            
            ::wm::widget rset $path \
                osd_w {[expr {4*$sz}]} \
                osd_h {[expr {1*$sz}]} \
                osd_bordersize {[expr {0.1*$sz}]} \
                osd_borderrgba {0x404040FF} \
                osd_rgba {0x808080FF} \
                text.osd_text "Button" \
                text.osd_font {$font_sans} \
                text.osd_x {[expr {1.5*$sz/6.}]} \
                text.osd_y {[expr {-0.0*$sz/6.}]} \
                text.osd_size {[expr {45*$sz/60}]} \
                text.osd_rgba {0x404040FF} \
                is_clickable {} \
                on_mouse_button1_down {  } \
                on_mouse_button1_up   { rset osd_rgba 0x808080FF } \
                {*}$args
            
        }

        proc dropdown_button {path args} {

            ::wm::widget add $path button
            
            ::wm::widget rset $path \
                selected "A" \
                choices [list "A" "B" "C"] \
                text.osd_text "A" \
                on_mouse_button1_down { 
                    
                    lassign [osd info "wm" -mousecoord] x y
                    rset osd_rgba 0xC0C0C0FF
                    
                    ::wm::widget add "wm.tmp_window" rectangle
                    set idx 0
                    foreach choice [rget choices] {
                        ::wm::widget add "wm.tmp_window.$idx" rectangle
                        ::wm::widget add "wm.tmp_window.$idx.text" text

                        ::wm::widget rset "wm.tmp_window.$idx" \
                            osd_x 0 \
                            osd_y [expr {$idx*[rsub osd_h]}] \
                            osd_h [rsub osd_h] \
                            osd_w [rsub osd_w] \
                            osd_bordersize {[expr {0.1*$sz}]} \
                            osd_borderrgba {0x404040FF} \
                            osd_rgba {0x808080FF} \
                            text.osd_text $choice \
                            text.osd_font {$font_sans} \
                            text.osd_x {[expr {1.5*$sz/6.}]} \
                            text.osd_y {[expr {0.25*$sz/6.}]} \
                            text.osd_size {[expr {5*$sz/6}]} \
                            text.osd_rgba {0x404040FF}
                            
                        incr idx
                    }
                   
                    ::wm::widget rset "wm.tmp_window" \
                        choices [rget choices] \
                        osd_relx $x \
                        osd_rely $y \
                        osd_h [expr {$idx*[rsub osd_h]}] \
                        osd_w [rsub osd_w] \
                        on_mouse_motion {
                            set idx 0
                            foreach choice [rget choices] {
                                if {[wm::callbacks::is_mouse_over "wm.tmp_window.$idx"]} {
                                    rset $idx.osd_rgba 0xC0C0C0FF
                                } else {
                                    rset $idx.osd_rgba 0x808080FF 
                                }
                                incr idx
                            }
                        }
                    
                } \
                on_mouse_button1_up   { 
                    
                    rset osd_rgba 0x808080FF 
                    
                    set idx 0
                    foreach choice [rget choices] {
                        if {[wm::callbacks::is_mouse_over "wm.tmp_window.$idx"]} {
                            rset selected $choice
                            rset text.osd_text $choice
                        }
                        incr idx
                    }
                    
                    ::wm::widget remove "wm.tmp_window"
                } \
                {*}$args
            
        }
    }


    namespace eval callbacks {

        proc upkeep {} {

            if {![dict exists $::wm::Status widgets wm]} { return }
            
            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.on_upkeep$} $path match parent]} {
                    ::wm::widget reval $parent on_upkeep
                }
            }

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.([^\.]*)_autoupdate$} $path match parent parameter]} {

                    dict with ::wm::Configuration {}
                    set current [::wm::widget rsub $parent $parameter]
                    set target  [::wm::widget rsub $parent ${parameter}_autoupdate]
                    if {[expr {abs($current-$target)}]>1} { 
                        ::wm::widget rset $parent $parameter [expr {$smoothness*$current+(1-$smoothness)*$target}]
                    } else {
                        ::wm::widget rset $parent $parameter [::wm::widget rget $parent ${parameter}_autoupdate]
                        ::wm::widget runset $parent ${parameter}_autoupdate
                    }
                }
            }
            
            foreach global_path [dict keys [dict get $::wm::Status to_update]] {
                if {[regexp {^(.*)\.osd_([^\._]*)$} $global_path global_path osd_id parameter]} {
                    #puts stderr "Updating $osd_id $parameter [::wm::widget rsub $global_path {}]"
                    osd configure $osd_id -$parameter [::wm::widget rsub $global_path {}]
                }
            }
            dict set ::wm::Status to_update [dict create]
            
            
            after "realtime" 0.020 ::wm::callbacks::upkeep
            return
        }

        proc on_mouse_button1_down {event_info} {
            
            if {![dict exists $::wm::Status widgets wm]} { return }

            #puts stderr "Event! $event_info"

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.is_clickable$} $path match parent]} {
                    if {[is_mouse_over $parent]==1} {
                        ::wm::widget rset $parent is_pressed {}
                        ::wm::widget reval $parent on_mouse_button1_down $event_info
                    }                                        
                }
            }
        }

        proc on_mouse_button1_up {event_info} {
            
            if {![dict exists $::wm::Status widgets wm]} { return }
            
            #puts stderr "Event! $event_info"

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.is_clickable$} $path match parent]} {

                    if {[::wm::widget rexists $parent is_pressed]} {
                        if {[is_mouse_over $parent]} {
                            ::wm::widget reval $parent on_activation $event_info
                        }
                        ::wm::widget reval $parent on_mouse_button1_up $event_info
                        ::wm::widget runset $parent is_pressed $event_info
                    }
                }
            }
        }

        proc on_mouse {event_info} {
            
            if {![dict exists $::wm::Status widgets wm]} { return }

            #puts stderr "Catch All Event! $event_info"
            lassign $event_info device type

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.on_mouse_([^\._]*)$} $path match parent requested_type]} {
                    if {$requested_type==$type} {
                        ::wm::widget reval $parent "on_mouse_$type" $event_info
                    }
                }
            }
        }

        proc is_mouse_over {path} {
            
            set ret 0
            if {[osd exists $path]} {
                catch {
                    lassign [osd info $path -mousecoord] x y
                    if {($x >= 0) && ($x <= 1) && ($y >= 0) && ($y <= 1)} {
                        set ret 1
                    }
                }
            }
            return $ret
        }
    }


    namespace eval defaults {

        proc Status {} { return [dict create \
            widgets [dict create] \
        ]}

        proc Configuration {} { return [dict create \
            font_mono "skins/DejaVuSansMono.ttf" \
            font_sans "skins/DejaVuSans.ttf" \
            sz 24 \
            width 25 \
            smoothness 0.6 \
        ]}
    }
}
