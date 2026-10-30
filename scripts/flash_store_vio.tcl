# P2 helpers for an ALREADY connected/programmed target. No target/program/reset.
# One owner only. A timeout is UNKNOWN: query before retrying, never auto-save.
source [file join [file dirname [info script]] runtime_calibration_vio.tcl]
namespace eval rc_store {}
proc rc_store::core {} {
    set c [get_hw_vios -quiet -filter {CELL_NAME =~ "*u_vio_flash_store*"}]
    if {[llength $c]!=1} {error "Persistent flash VIO missing; matching P2 bit/LTX required"}
    return [lindex $c 0]
}
proc rc_store_status {} {
    set c [rc_store::core]
    refresh_hw_vio -update_output_values $c
    set before [list [rc::input $c store_status] [rc::input $c store_sequence] [rc::input $c store_saved_epoch]]
    set bank [rc::input $c store_saved_bank]
    set id [rc::input $c store_jedec]
    refresh_hw_vio $c
    set after [list [rc::input $c store_status] [rc::input $c store_sequence] [rc::input $c store_saved_epoch]]
    if {$before ne $after} {error "Storage snapshot changed; query again"}
    lassign $after f sequence epoch
    return [dict create stage PERSISTENT busy [expr {$f&1}] ready [expr {($f>>1)&1}] \
        saved_valid [expr {($f>>2)&1}] source [expr {($f>>3)&3}] error [expr {($f>>5)&15}] \
        ack [expr {($f>>9)&1}] initialized [expr {($f>>10)&1}] dirty [expr {($f>>11)&1}] \
        saving [expr {($f>>12)&1}] apply_block [expr {($f>>13)&1}] rejected [expr {($f>>14)&1}] \
        panel_pending [expr {($f>>15)&1}] status_register [expr {($f>>16)&255}] security_register [expr {($f>>24)&255}] \
        jedec $id sequence $sequence saved_epoch $epoch bank $bank]
}
proc rc_store::active {} {
    set c [rc::core];refresh_hw_vio $c
    set ep [rc::input $c epoch]
    set flags [rc::input $c flags]
    set bank [expr {(($flags&1)<<96)|([rc::input $c active_vpp]<<64)|([rc::input $c active_rms]<<32)|[rc::input $c active_fft]}]
    refresh_hw_vio $c
    if {$ep!=[rc::input $c epoch] || $flags!=[rc::input $c flags]} {error "Active calibration changed; query again"}
    return [dict create bank $bank epoch $ep flags $flags]
}
proc rc_store::request {operation} {
    set s [rc_store_status]
    if {![dict get $s initialized] || [dict get $s busy] || ![dict get $s ready]} {error "Storage not idle; no request issued"}
    set c [rc_store::core]
    set p [rc::probe $c store_request]
    set old [rc::hexvalue $p OUTPUT_VALUE]
    if {$old!=[dict get $s ack]} {error "Prior storage request pending/unknown; no retry"}
    set cmd [rc::probe $c store_command]
    set_property OUTPUT_VALUE_RADIX HEX $cmd
    set_property OUTPUT_VALUE [format %x $operation] $cmd
    commit_hw_vio $cmd
    set target [expr {1-$old}]
    set_property OUTPUT_VALUE_RADIX HEX $p
    set_property OUTPUT_VALUE $target $p
    commit_hw_vio $p
    set deadline [expr {[clock milliseconds]+10000}]
    while {1} {
        if {![catch {set s [rc_store_status]}] && [dict get $s ack]==$target && ![dict get $s busy]} {
            if {[dict get $s rejected]} {error "Illegal overlapping command rejected; inspect current saved bank"}
            return $s
        }
        if {[clock milliseconds]>=$deadline} {error "Storage timeout: persistence state UNKNOWN; query, do not repeat save"}
        after 20
    }
}
proc rc_save {} {
    set before [rc_store_status]
    if {[dict get $before jedec]!=0xc22016 || ([dict get $before status_register]&0xbd)!=0 ||
        ([dict get $before security_register]&0xe0)!=0} {error "Flash profile/protection/WIP check failed; no save issued"}
    set a [rc_store::active]
    if {([dict get $a flags]&32)!=0} {error "Apply blocked; no save issued"}
    set result [rc_store::request 1]
    if {[dict get $result error]!=0 || ![dict get $result saved_valid]} {error "Save failed, code [dict get $result error]; inspect before any retry"}
    if {[dict get $result bank]!=[dict get $a bank]} {error "Saved bank differs from requested applied snapshot; do not retry"}
    set unchanged [expr {[dict get $before saved_valid] && [dict get $before bank]==[dict get $a bank] && [dict get $before sequence]==[dict get $result sequence]}]
    if {!$unchanged && [dict get $result saved_epoch]!=[dict get $a epoch]} {error "Saved epoch mismatch; inspect"}
    dict set result disposition [expr {$unchanged?"UNCHANGED":"SAVED_AND_VERIFIED"}]
    return $result
}
proc rc_reload {} {
    set result [rc_store::request 2]
    set a [rc_store::active]
    if {[dict get $result saved_valid] && [dict get $a bank]!=[dict get $result bank]} {error "Restored bank not active"}
    if {![dict get $result ready]} {error "Restore not ready"}
    dict set result active $a
    return $result
}
proc rc_store_probe {} {return [rc_store::request 0]}
proc rc_store::json_string {s} {
    return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $s]\""
}
proc rc_store::record_crc {s} {
    set bank [dict get $s bank]
    set bytes [binary format H* 4743414c01004000]
    foreach word [list [dict get $s sequence] 65537 [expr {($bank>>96)&1}] \
        [expr {($bank>>64)&0xffffffff}] [expr {($bank>>32)&0xffffffff}] [expr {$bank&0xffffffff}] \
        [dict get $s saved_epoch] 0 0 0 0 0] {
        set b {};for {set n 0} {$n<4} {incr n} {lappend b [expr {($word>>($n*8))&255}]}
        append bytes [binary format c* $b]
    }
    return [expr {[zlib crc32 $bytes]&0xffffffff}]
}
proc rc_export {path {build_id unknown}} {
    set s [rc_store_status];set a [rc_store::active]
    if {[dict get $s busy]} {error "Do not export an in-flight storage transaction"}
    set output [open $path {WRONLY CREAT EXCL}]
    try {
        set board unknown
        catch {set board [get_property NAME [current_hw_target]]}
        set fields [list "\"format\":1" "\"compatibility\":65537" "\"units\":\"Q16.16 uV/raw; FFT=sine peak\"" \
            "\"build_id\":[rc_store::json_string $build_id]" \
            "\"board_target\":[rc_store::json_string $board]" \
            "\"timestamp_utc\":[rc_store::json_string [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]]"]
        foreach name {jedec saved_valid source sequence saved_epoch dirty error} {lappend fields "\"$name\":[dict get $s $name]"}
        foreach {prefix value} [list saved [dict get $s bank] active [dict get $a bank]] {
            lappend fields "\"${prefix}_enabled\":[expr {($value>>96)&1}]"
            foreach {name shift} {vpp 64 rms 32 fft 0} {lappend fields "\"${prefix}_${name}_gain\":[expr {($value>>$shift)&0xffffffff}]"}
        }
        lappend fields "\"active_epoch\":[dict get $a epoch]"
        lappend fields "\"record_crc_reconstructed\":[expr {[dict get $s saved_valid]?[rc_store::record_crc $s]:"null"}]"
        puts $output "\{[join $fields ,]\}"
    } finally {close $output}
    return $s
}
