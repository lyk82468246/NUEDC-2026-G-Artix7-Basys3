# Read one NEW FPGA measurement through the existing ILA. Never program FPGA.
# vivado -mode batch -source scripts/capture_hw_ila.tcl -tclargs OUT.csv MATCHING.ltx
if {[llength $argv] != 2} { error "Expected OUT.csv MATCHING.ltx" }
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
stop_hw_ila $ila
# Restore controls and all comparators before selecting the sole trigger.
reset_hw_ila $ila
set trigger [get_hw_probes -quiet -of_objects $ila -filter {NAME =~ "*measurement_valid*"}]
if {[llength $trigger] != 1} { error "Missing measurement_valid trigger probe" }
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trigger
set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
run_hw_ila $ila
# Vivado's -timeout unit is MINUTES (UG835): 0.25 min = 15 seconds.
if {[catch {wait_on_hw_ila -timeout 0.25 $ila} message]} {
    stop_hw_ila $ila
    error "No fresh measurement within 15 seconds: $message"
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file $csv_path $data
close_hw_target
disconnect_hw_server
close_hw_manager
puts "Fresh ILA capture: $csv_path"
