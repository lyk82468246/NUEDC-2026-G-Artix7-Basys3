# Read-only Hardware Manager helper. No connection/programming/erase/reset calls.
source [file join [file dirname [info script]] runtime_calibration_vio.tcl]
namespace eval rc_store {}
proc rc_store::core {} {
    set c [get_hw_vios -quiet -filter {CELL_NAME =~ "*u_vio_flash_calibration*"}]
    if {[llength $c]!=1} {error "P1 flash VIO missing; matching new bit/LTX required"}
    return [lindex $c 0]
}
proc rc_store_status {} {
    set c [rc_store::core]
    refresh_hw_vio -update_output_values $c
    set flags [rc::input $c flash_status]
    return [dict create stage READ_ONLY busy [expr {$flags&1}] ready [expr {($flags>>1)&1}] \
        valid [expr {($flags>>2)&1}] source [expr {($flags>>3)&3}] error [expr {($flags>>5)&15}] \
        ack [expr {($flags>>9)&1}] initialized [expr {($flags>>10)&1}] status_register [expr {($flags>>11)&255}] \
        jedec [rc::input $c flash_jedec] sequence [rc::input $c flash_sequence] \
        saved_epoch [rc::input $c flash_saved_epoch] bank [rc::input $c flash_bank]]
}
proc rc_store_probe {} {
    set s [rc_store_status]
    if {![dict get $s initialized] || [dict get $s busy] || ![dict get $s ready]} {error "Flash probe busy; do not queue requests"}
    set c [rc_store::core]
    set p [rc::probe $c flash_request]
    set old [rc::hexvalue $p OUTPUT_VALUE]
    if {$old!=[dict get $s ack]} {error "Prior flash request pending; state unknown"}
    set target [expr {1-$old}]
    set_property OUTPUT_VALUE_RADIX HEX $p
    set_property OUTPUT_VALUE $target $p
    commit_hw_vio $p
    set deadline [expr {[clock milliseconds]+3000}]
    while {1} {
        set s [rc_store_status]
        if {[dict get $s ack]==$target && ![dict get $s busy] && [dict get $s ready]} {return $s}
        if {[clock milliseconds]>=$deadline} {error "Probe timed out; status unknown, query before retry"}
        after 20
    }
}
proc rc_save {args} {error "READ_ONLY_STAGE: persistent save RTL is not enabled; no write issued"}
proc rc_reload {args} {error "READ_ONLY_STAGE: use rc_store_probe to inspect; active bank restore is not integrated yet"}
