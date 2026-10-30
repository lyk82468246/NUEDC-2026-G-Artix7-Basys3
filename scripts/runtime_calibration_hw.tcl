# Bounded hardware session for an ALREADY PROGRAMMED device. No bit/reset.
# OUT.txt matching.ltx inspect|read|apply [vpp_q16 rms_q16 fft_q16 enabled]
if {[llength $argv]<3} {error "Expected output, LTX, action"}
set rc_output [file normalize [lindex $argv 0]]
set rc_ltx [file normalize [lindex $argv 1]]
set rc_action [lindex $argv 2]
if {$rc_action ni {inspect read apply flash_status flash_probe store_status store_probe store_save store_reload store_export}} {error "Unsupported calibration operation"}
if {[file exists $rc_output] || ![file exists $rc_ltx]} {error "Output exists or LTX missing"}
if {($rc_action eq "apply" && [llength $argv]!=7) || ($rc_action ne "apply" && [llength $argv]!=3)} {
    error "Incorrect argument count"
}
set rc_opened 0
open_hw_manager
try {
    connect_hw_server -url localhost:3121
    set rc_targets [get_hw_targets -quiet]
    if {[llength $rc_targets]!=1} {error "Expected one JTAG target"}
    current_hw_target [lindex $rc_targets 0]
    open_hw_target
    set rc_opened 1
    set rc_devices [get_hw_devices -quiet -filter {PART =~ "xc7a35t*"}]
    if {[llength $rc_devices]!=1} {error "Expected one programmed Artix7 35T"}
    set rc_device [lindex $rc_devices 0]
    current_hw_device $rc_device
    set_property PROBES.FILE $rc_ltx $rc_device
    refresh_hw_device $rc_device
    source [file join [file dirname [info script]] runtime_calibration_vio.tcl]
    if {$rc_action in {flash_status flash_probe}} {
        source [file join [file dirname [info script]] flash_readonly_vio.tcl]
        set rc_result [dict create action $rc_action]
        dict set rc_result flash [expr {$rc_action eq "flash_probe" ? [rc_store_probe] : [rc_store_status]}]
    } elseif {[string match store_* $rc_action]} {
        source [file join [file dirname [info script]] flash_store_vio.tcl]
        set rc_result [dict create action $rc_action]
        switch -- $rc_action {
            store_status {dict set rc_result flash [rc_store_status]}
            store_probe {dict set rc_result flash [rc_store_probe]}
            store_save {dict set rc_result flash [rc_save]}
            store_reload {dict set rc_result flash [rc_reload]}
            store_export {dict set rc_result flash [rc_export "${rc_output}.json"]}
        }
    } else {
    set rc_core [rc::core]
    refresh_hw_vio -update_output_values $rc_core
    puts "RC_CORE $rc_core"
    set rc_result [dict create action $rc_action]
    if {$rc_action eq "inspect"} {
        set rc_probes {}
        foreach rc_p [get_hw_probes -of_objects $rc_core] {
            set rc_item [dict create NAME [get_property NAME $rc_p]]
            foreach rc_property {INPUT_VALUE OUTPUT_VALUE PORT_INDEX PORT_TYPE WIDTH} {
                if {$rc_property in [list_property $rc_p]} {
                    dict set rc_item $rc_property [get_property $rc_property $rc_p]
                }
            }
            lappend rc_probes $rc_item
            puts "RC_PROBE $rc_item"
        }
        dict set rc_result probes $rc_probes
    } elseif {$rc_action eq "apply"} {
        dict set rc_result applied [rc_apply {*}[lrange $argv 3 6]]
    } else {
        set rc_first [rc_read]
        set rc_until [expr {[clock milliseconds]+10000}]
        while {1} {
            after 100
            if {![catch {set rc_next [rc_read]} rc_read_error]} {
                if {[dict get $rc_next result_count]!=[dict get $rc_first result_count]} {break}
            }
            if {[clock milliseconds]>=$rc_until} {error "No stable fresh VIO packet within 10s: $rc_read_error"}
        }
        dict set rc_result first $rc_first
        dict set rc_result result $rc_next
        dict set rc_result fresh 1
    }
    }
    set rc_stream [open $rc_output {WRONLY CREAT EXCL}]
    puts $rc_stream $rc_result
    close $rc_stream
    puts "RC_RESULT $rc_result"
} finally {
    if {$rc_opened} {catch {close_hw_target}}
    catch {disconnect_hw_server}
    close_hw_manager
}
