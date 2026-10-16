# Connect one Basys 3, optionally program an explicitly supplied existing bit.
# vivado -mode batch -source setup_hw_session.tcl -tclargs MATCHING.ltx [FILE.bit]
if {[llength $argv] < 1 || [llength $argv] > 2} { error "Expected MATCHING.ltx and optional FILE.bit" }
set probes [file normalize [lindex $argv 0]]
if {![file isfile $probes]} { error "Missing LTX: $probes" }
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} { error "Expected exactly one JTAG target, found [llength $targets]" }
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet -filter {PART =~ "xc7a35t*"}]
if {[llength $devices] != 1} { error "Expected one Artix-7 35T" }
set device [lindex $devices 0]
current_hw_device $device
set_property PROBES.FILE $probes $device
if {[llength $argv] == 2} {
    set bit [file normalize [lindex $argv 1]]
    if {![file isfile $bit]} { error "Missing bitstream: $bit" }
    set_property PROGRAM.FILE $bit $device
    program_hw_devices $device
}
refresh_hw_device $device
puts "HARDWARE_DEVICE=$device"
foreach property [list_property $device] {
    if {[regexp {^(PART|PROGRAM\.|REGISTER.CONFIG_STATUS)} $property]} {
        puts "$property=[get_property $property $device]"
    }
}
set ilas [get_hw_ilas -quiet -of_objects $device]
puts "ILA_COUNT=[llength $ilas]"
foreach ila $ilas {
    puts "ILA=$ila CELL=[get_property CELL_NAME $ila]"
    foreach probe [get_hw_probes -of_objects $ila] { puts "PROBE=$probe" }
}
close_hw_target
disconnect_hw_server
close_hw_manager
