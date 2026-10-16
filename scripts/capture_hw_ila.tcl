# Read one NEW FPGA measurement through the existing ILA. Never program FPGA.
# vivado -mode batch -source scripts/capture_hw_ila.tcl -tclargs OUT.csv MATCHING.ltx
if {[llength $argv] < 2 || [llength $argv] > 3} { error "Expected OUT.csv MATCHING.ltx and optional immediate" }
set immediate 0
if {[llength $argv] == 3} {
    if {[lindex $argv 2] ne "immediate"} { error "Only immediate diagnostic mode is supported" }
    set immediate 1
}
set csv_path [file normalize [lindex $argv 0]]
set ltx_path [file normalize [lindex $argv 1]]
if {![file exists $ltx_path]} { error "Probe file missing: $ltx_path" }
if {[file exists $csv_path]} { error "Refusing to overwrite: $csv_path" }
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} { error "Expected exactly one JTAG target; found [llength $targets]" }
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet -filter {PART =~ "xc7a35t*"}]
if {[llength $devices] != 1} { error "Expected one programmed Artix-7 35T device" }
set device [lindex $devices 0]
current_hw_device $device
set_property PROBES.FILE $ltx_path $device
refresh_hw_device $device
set ilas [get_hw_ilas -quiet -of_objects $device -filter {CELL_NAME =~ "*u_ila_system*"}]
if {[llength $ilas] != 1} { error "Expected u_ila_system; check programmed bit/ltx match" }
set ila [lindex $ilas 0]
# Restore controls and all comparators before selecting the sole trigger.
reset_hw_ila $ila
set trigger [get_hw_probes -quiet -of_objects $ila -filter {NAME =~ "*measurement_valid*"}]
if {[llength $trigger] != 1} { error "Missing measurement_valid trigger probe" }
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trigger
# reset_hw_ila already restores these defaults. Basic-only cores expose some
# CONTROL properties as read-only; verify instead of redundantly writing them.
foreach {property expected} {
    CONTROL.TRIGGER_MODE BASIC_ONLY
    CONTROL.TRIGGER_CONDITION AND
    CONTROL.TRIGGER_POSITION 0
    CONTROL.CAPTURE_MODE ALWAYS
} {
    if {[get_property $property $ila] ne $expected} {
        error "Unexpected reset value for $property: [get_property $property $ila]"
    }
}
if {$immediate} {
    run_hw_ila -trigger_now $ila
} else {
    run_hw_ila $ila
}
# Vivado's -timeout unit is MINUTES (UG835): 0.25 min = 15 seconds.
if {[catch {wait_on_hw_ila -timeout 0.25 $ila} message]} {
    error "No fresh measurement within 15 seconds: $message"
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file $csv_path $data
set csv_stream [open $csv_path r]
set csv_text [read $csv_stream]
close $csv_stream
if {[llength [split [string trim $csv_text] "\n"]] < 3} {
    error "ILA did not capture any samples before the timeout"
}
close_hw_target
disconnect_hw_server
close_hw_manager
puts "ILA capture (immediate=$immediate): $csv_path"
