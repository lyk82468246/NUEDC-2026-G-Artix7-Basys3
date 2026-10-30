# Run in OPEN Vivado GUI. Registers read-only P1 core, VIO, timing and generic.
# Never synthesizes, routes, creates bit/MCS, programs or erases a device.
if {[llength [get_projects -quiet]]!=1} {error "Open G_FPGA first"}
set fp_root [file normalize [file join [file dirname [info script]] ..]]
if {[file normalize [get_property DIRECTORY [current_project]]] ne $fp_root} {error "Wrong project"}
foreach fp_name {Flash_SPI_Byte Flash_Read_Engine Calibration_Record_Decoder Calibration_Record_Select Calibration_Flash_Restore Flash_Readonly_Probe} {
    set fp_path [file join $fp_root sources rtl ${fp_name}.v]
    if {![file exists $fp_path]} {error "Missing $fp_path"}
    if {[llength [get_files -quiet $fp_path]]==0} {add_files -fileset sources_1 -norecurse $fp_path}
    foreach fp_usage {USED_IN_SYNTHESIS USED_IN_IMPLEMENTATION USED_IN_SIMULATION} {set_property $fp_usage true [get_files $fp_path]}
}
set fp_timing [file join $fp_root sources constraints Flash_Readonly_Timing.xdc]
if {[llength [get_files -quiet $fp_timing]]==0} {add_files -fileset constrs_1 -norecurse $fp_timing}
set_property PROCESSING_ORDER LATE [get_files $fp_timing]
set fp_ip [get_ips -quiet vio_flash_calibration]
if {[llength $fp_ip]==0} {
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_flash_calibration -dir [file join $fp_root sources ip]
    set fp_ip [get_ips vio_flash_calibration]
}
set fp_props [list CONFIG.C_NUM_PROBE_IN 5 CONFIG.C_NUM_PROBE_OUT 1 CONFIG.C_PROBE_OUT0_WIDTH 1 CONFIG.C_PROBE_OUT0_INIT_VAL 0x0]
foreach {fp_n fp_width} {0 32 1 24 2 32 3 32 4 97} {lappend fp_props CONFIG.C_PROBE_IN${fp_n}_WIDTH $fp_width}
set_property -dict $fp_props $fp_ip
generate_target all $fp_ip
set fp_generics {}
foreach fp_generic [get_property generic [get_filesets sources_1]] {
    if {![string match ENABLE_FLASH_READONLY_PROBE=* $fp_generic]} {lappend fp_generics $fp_generic}
}
lappend fp_generics ENABLE_FLASH_READONLY_PROBE=1
set_property generic $fp_generics [get_filesets sources_1]
puts "P1 READ-ONLY probe enabled: 05/9F/03 only, NO WREN/erase/program path."
puts "User must manually build/check timing+DRC and program matching bit/LTX."
puts "Runtime calibration remains volatile; decoded records are NOT applied yet."
