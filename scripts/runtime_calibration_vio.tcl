# Source in Hardware Manager AFTER new bit + matching LTX have been loaded.
# No open_target/program/reset: use the current user's connection exclusively.
# Stop automated lab/ILA jobs before using this library. Never edit staging
# manually during rc_apply; unknown/busy state is an error, not a retry.
namespace eval rc {}
proc rc::core {} {
    set cores [get_hw_vios -quiet -filter {CELL_NAME =~ "*u_vio_calibration*"}]
    if {[llength $cores]!=1} {error "Expected one calibration VIO; new bit/LTX required"}
    return [lindex $cores 0]
}
proc rc::probe {core signal} {
    set found {}
    set pattern [format {(^|/)%s(\[[0-9:]+\])?$} $signal]
    foreach p [get_hw_probes -quiet -of_objects $core] {
        if {[regexp $pattern [get_property NAME $p]]} {lappend found $p}
    }
    if {[llength $found]!=1} {error "Expected unique VIO signal $signal; inspect get_hw_probes names"}
    return [lindex $found 0]
}
proc rc::hexvalue {p property} {
    set v [string trim [get_property $property $p]]
    if {[string match 0x* $v]} {set v [string range $v 2 end]}
    if {![regexp {^[0-9a-fA-F]+$} $v]} {error "Unknown VIO value: $v"}
    # Tcl scan %x may sign-extend 0xffffffff to -1. The strict hex regex above
    # makes this expression safe and retains the unsigned arbitrary precision.
    return [expr "0x$v"]
}
proc rc::input {c signal} {return [rc::hexvalue [rc::probe $c $signal] INPUT_VALUE]}
proc rc_apply {vpp rms fft {enabled 1}} {
    foreach value [list $vpp $rms $fft] {
        if {![string is entier -strict $value] || $value<0 || $value>0xffffffff} {error "Gain must be uint32"}
        if {$enabled && $value==0} {error "Enabled gains must be nonzero"}
    }
    if {$enabled ni {0 1}} {error "enabled must be 0/1"}
    set c [rc::core]
    refresh_hw_vio -update_output_values 1 $c
    set request [rc::probe $c request]
    set old [rc::hexvalue $request OUTPUT_VALUE]
    if {[rc::input $c ack]!=$old} {error "Prior commit pending; do not overwrite staging"}
    set staged {}
    foreach {signal value} [list staged_vpp $vpp staged_rms $rms staged_fft $fft staged_valid $enabled] {
        set p [rc::probe $c $signal]
        set_property OUTPUT_VALUE [format %x $value] $p
        lappend staged $p
    }
    commit_hw_vio $staged
    # Separate JTAG transaction is essential: staging is stable before request.
    set target [expr {1-$old}]
    set_property OUTPUT_VALUE $target $request
    commit_hw_vio $request
    set until [expr {[clock milliseconds]+2000}]
    while {1} {
        refresh_hw_vio $c
        if {[rc::input $c ack]==$target} {break}
        if {[clock milliseconds]>=$until} {error "Commit timeout; bank state unknown, inspect before retry"}
        after 20
    }
    foreach {signal value} [list active_vpp $vpp active_rms $rms active_fft $fft] {
        if {[rc::input $c $signal]!=$value} {error "Applied bank mismatch: $signal"}
    }
    if {([rc::input $c flags]&1)!=$enabled} {error "Applied calibration-valid mismatch"}
    return [dict create applied_epoch [rc::input $c epoch] enabled $enabled]
}
proc rc_read {} {
    set c [rc::core]
    # VIO reads are sequential/live; compare version+counter twice. No label
    # "fresh" unless caller sees result_count advance since its prior read.
    refresh_hw_vio $c
    set before [list [rc::input $c count] [rc::input $c result_epoch] [rc::input $c epoch]]
    set flags [rc::input $c flags]
    set result [dict create vpp_uv [rc::input $c vpp_uv] rms_uv [rc::input $c rms_uv] peak_uv [rc::input $c peak_uv] flags $flags]
    refresh_hw_vio $c
    set after [list [rc::input $c count] [rc::input $c result_epoch] [rc::input $c epoch]]
    set flags2 [rc::input $c flags]
    if {$before ne $after || $flags!=$flags2 || ($flags&8)!=0} {error "Result changed/in progress; read again"}
    if {[lindex $after 1]!=[lindex $after 2]} {error "Last result uses previous coefficient epoch"}
    dict set result result_count [lindex $after 0]
    dict set result epoch [lindex $after 1]
    dict set result valid [expr {($flags&3)==3 && ($flags&20)==0}]
    return $result
}
