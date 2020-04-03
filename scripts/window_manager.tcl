

namespace eval wm {

    if ![info exists Status] { variable Status [dict create] }
    if ![info exists Configuration] { variable Configuration [dict create] }

    proc start {} {

        if {[dict size $::wm::Status]==0} { set ::wm::Status [::wm::defaults::Status] } 
        if {[dict size $::wm::Configuration]==0} { set ::wm::Configuration [::wm::defaults::Configuration] } 
        
        dict set ::wm::Status enabled 1
                
        after "20" ::wm::callbacks::upkeep
        after "mouse button1 down" ::wm::callbacks::on_mouse_button1_down
        after "mouse button1 up" ::wm::callbacks::on_mouse_button1_up
        after "mouse motion" ::wm::callbacks::on_mouse_motion
    }

    proc stop {} {
        
        dict unset ::wm::Status enabled
    }

    proc reload_configuration {} {
    }

    namespace eval widget_commands {

        proc update {id args} {

            if {![dict exists $::wm::Status enabled]} {::wm::start}
                        
            foreach {arg value} $args {
                switch $value {
                    unset { dict set ::wm::Status widgets ${id.$arg} }
                    reload {}
                    default { dict set ::wm::Status widgets ${id.$arg} $value }
            }

            regexp {^(.*)[\.][^\.]*$} $widget_id match parent_id
            dict with ::wm::Configuration {}
            dict with ::wm::Status widgets $widget_id {}

            foreach {arg value} $args {
                if {[regexp {^([^\.]*)(.*)[\.]([^\.]*)$} $arg match prefix children parameter] && $prefix == "-osd"} {
                    #puts stderr [list osd configure "$widget_id$children" "-$parameter" $value [subst $value]]               
                    osd configure "$widget_id$children" "-$parameter" [subst $value]                   
                }
            }
        }

        proc add {widget_type widget_id args} {
            
            if {![dict exists $::wm::Status enabled]} {::wm::start}

            if {[namespace which ${widget_type}] != {}} {
                ${widget_type} $widget_id {*}$args
                return
            }            
            
            if {[namespace which ::wm::widgets::${widget_type}] != {}} {
                ::wm::widgets::${widget_type} $widget_id {*}$args
                return
            }

            osd create $widget_type $widget_id
            dict set ::wm::Status widgets $widget_id [dict create]
            
            ::wm::widget update $widget_id {*}$args
        }

        proc remove {widget_id} {
            
            if {![dict exists $::wm::Status widgets $widget_id]} {
                error "Trying to remove an unknown widget: $widget_id"
                return
            }
                
            dict unset ::wm::Status widgets $widget_id
            osd destroy $widget_id
            foreach { children_id } [dict keys [dict get $::wm::Status widgets] "${widget_id}\.*"] {
                dict unset ::wm::Status widgets $children_id
            }
        }
        

    }
    
    proc widget {command args} {
        switch $command {
            add    { return [widget_commands::add    {*}$args] }
            remove { return [widget_commands::remove {*}$args] }
            update { return [widget_commands::update {*}$args] }
        }
        error "Unknown widget command: \"$command\""
    }

    namespace eval widgets {
                
        proc dock {widget_id args} {
            
            ::wm::widget add rectangle $widget_id
            ::wm::widget add rectangle $widget_id.panel
            ::wm::widget add rectangle $widget_id.title
            ::wm::widget add text      $widget_id.title.text

            ::wm::widget update $widget_id \
                -osd.x {[expr {-10*$sz}]} \
                -target.osd.x 0 \
                -osd.y {[expr {4*$sz}]} \
                -osd.w {[expr {$sz*$width}]} \
                -osd.relh 1 \
                -osd.clip true \
                -osd.rgba {0x00000040} \
                -osd.title.x 0 \
                -osd.title.y 0 \
                -osd.title.w {[expr {($width-1)*$sz}]} \
                -osd.title.h {[expr {1*$sz}]} \
                -osd.title.rgba {0xFFFFFF40} \
                -osd.title.text.text "Dock" \
                -osd.title.text.font {$font_sans} \
                -osd.title.text.x {[expr {1.5*$sz/6.}]} \
                -osd.title.text.y {[expr {0.25*$sz/6.}]} \
                -osd.title.text.size {[expr {5*$sz/6}]} \
                -osd.title.text.rgba {0xFFFFFFFF} \
                -osd.panel.x 0 \
                -osd.panel.y {[expr {1*$sz}]} \
                -osd.panel.w {[expr {($width)*$sz}]} \
                -osd.panel.relh 1 \
                -osd.panel.clip true \
                -osd.panel.rgba {0x00000040} \
                {*}$args

            ::wm::widget add toggle_button $widget_id.hide \
                -textOn  "\u25BA" \
                -textOff "\u25C4" \
                -on_On  { ::wm::widget update $parent_id -target.osd.x {[expr {-($width-1)*$sz}]} } \
                -on_Off { ::wm::widget update $parent_id -target.osd.x 0 } \
                -osd.relx 1 \
                -osd.w {[expr {-1*$sz}]} \
                -osd.h {[expr {1*$sz}]} \
                -osd.text.x {[expr {1.5*$sz/6.-$sz}]} \
                -osd.text.y {[expr {-0.25*$sz/6.}]} \
                -osd.text.size {[expr {5*$sz/6}]} \
                -osd.text.font {$font_mono} 
        }

        proc window {widget_id args} {
            

            ::wm::widget add rectangle $widget_id
            ::wm::widget add rectangle $widget_id.panel
            ::wm::widget add rectangle $widget_id.title
            ::wm::widget add text      $widget_id.title.text

            ::wm::widget update $widget_id \
                -window_above {} \
                -window_below {} \
                -osd.x 0 \
                -osd.y 0 \
                -osd.w {[expr {$sz*$width}]} \
                -osd.h {[expr {2*$sz+[subst ${osd.panel.h}]}]} \
                -osd.clip true \
                -osd.rgba {0x00000040} \
                -osd.title.x 0 \
                -osd.title.y 0 \
                -osd.title.w {[expr {($width-1)*$sz}]} \
                -osd.title.h {[expr {1*$sz}]} \
                -osd.title.rgba {0xFFFFFF40} \
                -osd.title.text.text "Dock" \
                -osd.title.text.font {$font_sans} \
                -osd.title.text.x {[expr {1.5*$sz/6.}]} \
                -osd.title.text.y {[expr {0.25*$sz/6.}]} \
                -osd.title.text.size {[expr {5*$sz/6}]} \
                -osd.title.text.rgba {0xFFFFFFFF} \
                -osd.panel.x 0 \
                -osd.panel.h {[expr {1*$sz}]} \
                -osd.panel.y {[expr {1*$sz}]} \
                -osd.panel.w {[expr {($width)*$sz}]} \
                -osd.panel.relh 1 \
                -osd.panel.clip true \
                -osd.panel.rgba {0x00000040} \
                {*}$args

            ::wm::widget add toggle_button $widget_id.hide \
                -textOn  "\u25BC" \
                -textOff "\u25B2" \
                -on_On  { 
                    ::wm::widget update $parent_id -target.osd.h {[expr {1*$sz}]}
                    if {$window_below!={}} ::wm::widget update $window_below -target.osd.y {[expr {${osd.y}+1*$sz}]} 
                } \
                -on_Off { 
                    ::wm::widget update $parent_id -target.osd.h {[expr {2*$sz+[subst ${osd.panel.h}]}]} 
                    if {$window_below!={}} ::wm::widget update $window_below -target.osd.x {[expr {2*$sz}]} 
                } \
                -osd.relx 1 \
                -osd.w {[expr {-1*$sz}]} \
                -osd.h {[expr {1*$sz}]} \
                -osd.text.x {[expr {1.5*$sz/6.-$sz}]} \
                -osd.text.y {[expr {-0.25*$sz/6.}]} \
                -osd.text.size {[expr {5*$sz/6}]} \
                -osd.text.font {$font_mono} 
        }

        proc toggle_button {widget_id args} {
            
            ::wm::widget add button $widget_id \
                -is_toggled 0 \
                -textOn "On" \
                -textOff "Off" \
                -on_On {} \
                -on_Off {} \
                -on_activation { 
                    if {$is_toggled} {
                        dict set ::wm::Status widgets $widget_id is_toggled 0
                        eval $on_Off
                    } else {
                        dict set ::wm::Status widgets $widget_id is_toggled 1
                        eval $on_On
                    }
                    ::wm::widget update $widget_id -osd.text.text ${osd.text.text}
                } \
                -osd.text.text {[expr {$is_toggled?$textOn:$textOff}]} \
                {*}$args
        }

        proc button {widget_id args} {

            ::wm::widget add rectangle $widget_id 
            ::wm::widget add text $widget_id.text
            
            ::wm::widget update $widget_id \
                -osd.w {[expr {4*$sz}]} \
                -osd.h {[expr {1*$sz}]} \
                -osd.bordersize {[expr {0.1*$sz}]} \
                -osd.borderrgba {0x404040FF} \
                -osd.rgba {0x808080FF} \
                -osd.text.text "Button" \
                -osd.text.font {$font_sans} \
                -osd.text.x {[expr {1.5*$sz/6.}]} \
                -osd.text.y {[expr {0.25*$sz/6.}]} \
                -osd.text.size {[expr {5*$sz/6}]} \
                -osd.text.rgba {0x404040FF} \
                -on_press   { ::wm::widget update $widget_id -osd.rgba 0xC0C0C0FF } \
                -on_release { ::wm::widget update $widget_id -osd.rgba 0x808080FF } \
                {*}$args
            
        }
    }


    namespace eval callbacks {

        namespace eval util {
            
            proc callback {widget_id callback_id} {
                
                #We use the side effect of dict with: all keys get mapped as variables
                                    
                if {[dict exists $::wm::Status widgets $widget_id "on_$callback_id"]} {

                    regexp {^(.*)[\.][^\.]*$} $widget_id match parent_id
                    dict with ::wm::Configuration {}
                    dict with ::wm::Status widgets $widget_id {}
                    
                    eval [dict get $::wm::Status widgets $widget_id "on_$callback_id"]
                }
            }        
        }

        proc upkeep {} {

            if {![dict exists $::wm::Status enabled]} {start}
            
            dict for {widget_id widget} [dict get $::wm::Status widgets] {
                util::callback $widget_id upkeep

                foreach {key} [dict keys $widget {target.*}] {
                    if {[regexp {^target[.](.*)$} $key match sub_key]} {

                        regexp {^(.*)[\.][^\.]*$} $widget_id match parent_id
                        dict with ::wm::Configuration {}
                        dict with ::wm::Status widgets $widget_id {}
                        
                        set current [subst [dict get $widget $sub_key]]
                        set target [subst [dict get $widget $key]]
                        if {[expr {abs($current-$target)}]>1} {                            
                            ::wm::widget update $widget_id "-$sub_key" [expr {$smoothness*$current+(1-$smoothness)*$target}]
                        } else {
                            ::wm::widget update $widget_id "-$sub_key" [dict get $widget $key]
                            dict unset ::wm::Status widgets $widget_id $key
                        }
                    }
                }
            }
            
            after "20" ::wm::callbacks::upkeep
            return
        }

        proc on_mouse_button1_down {} {
            
            if {![dict exists $::wm::Status enabled]} return

            dict for {widget_id widget} [dict get $::wm::Status widgets] {
                if {[is_mouse_over $widget_id]==1} {
                    dict set ::wm::Status widgets $widget_id activated 1
                    util::callback $widget_id press
                }
            }
            after "mouse button1 down" ::wm::callbacks::on_mouse_button1_down
        }

        proc on_mouse_button1_up {} {
            
            if {![dict exists $::wm::Status enabled]} return

            dict for {widget_id widget} [dict get $::wm::Status widgets] {

                if {[is_mouse_over $widget_id] && [dict get $::wm::Status widgets $widget_id activated]} {
                    util::callback $widget_id activation
                }
                dict set ::wm::Status widgets $widget_id activated 0
                util::callback $widget_id release
            }
            after "mouse button1 up" ::wm::callbacks::on_mouse_button1_up
        }

        proc on_mouse_motion {} {
            
            if {![dict exists $::wm::Status enabled]} return

            dict for {widget_id widget} [dict get $::wm::Status widgets] {
                if {[is_mouse_over $widget_id]} {
                    util::callback $widget_id hover
                }
            }
            after "mouse motion" ::wm::callbacks::on_mouse_motion
       }

        proc is_mouse_over {widget_id} {
            
            set ret 0
            if {[osd exists $widget_id]} {
                catch {
                    lassign [osd info $widget_id -mousecoord] x y
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
            smoothness 0.8 \
        ]}
    }
}
