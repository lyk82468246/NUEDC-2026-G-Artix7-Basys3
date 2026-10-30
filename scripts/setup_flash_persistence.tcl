# OPEN GUI only. Registers/configures P2; NEVER builds, programs or erases.
if {[llength [get_projects -quiet]]!=1} {error "Open G_FPGA first"}
set fs_root [file normalize [file join [file dirname [info script]] ..]]
if {[file normalize [get_property DIRECTORY [current_project]]] ne $fs_root} {error "Wrong project"}
foreach fs_name {Flash_SPI_Byte Flash_Command_Engine Calibration_Record_Encoder Calibration_Record_Decoder Calibration_Record_Select Calibration_Store Runtime_Calibration} {
    set fs_path [file join $fs_root sources rtl ${fs_name}.v]
    if {![file exists $fs_path]} {error "Missing $fs_path"}
    if {[llength [get_files -quiet $fs_path]]==0} {add_files -fileset sources_1 -norecurse $fs_path}
    foreach fs_usage {USED_IN_SYNTHESIS USED_IN_IMPLEMENTATION USED_IN_SIMULATION} {set_property $fs_usage true [get_files $fs_path]}
}
set fs_timing [file join $fs_root sources constraints Flash_Store_Timing.xdc]
if {[llength [get_files -quiet $fs_timing]]==0} {add_files -fileset constrs_1 -norecurse $fs_timing}
set_property PROCESSING_ORDER LATE [get_files $fs_timing]
set fs_ip [get_ips -quiet vio_flash_store]
if {[llength $fs_ip]==0} {
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_flash_store -dir [file join $fs_root sources ip]
    set fs_ip [get_ips vio_flash_store]
}
set fs_props [list CONFIG.C_NUM_PROBE_IN 5 CONFIG.C_NUM_PROBE_OUT 2 \
    CONFIG.C_PROBE_OUT0_WIDTH 1 CONFIG.C_PROBE_OUT0_INIT_VAL 0x0 CONFIG.C_PROBE_OUT1_WIDTH 2 CONFIG.C_PROBE_OUT1_INIT_VAL 0x0]
foreach {fs_n fs_width} {0 32 1 24 2 32 3 32 4 97} {lappend fs_props CONFIG.C_PROBE_IN${fs_n}_WIDTH $fs_width}
set_property -dict $fs_props $fs_ip
generate_target all $fs_ip
set fs_generics {}
foreach fs_generic [get_property generic [get_filesets sources_1]] {
    if {![string match ENABLE_FLASH_PERSISTENCE=* $fs_generic] &&
        ![string match ENABLE_FLASH_READONLY_PROBE=* $fs_generic] &&
        ![string match ENABLE_RUNTIME_CALIBRATION=* $fs_generic]} {lappend fs_generics $fs_generic}
}
lappend fs_generics ENABLE_RUNTIME_CALIBRATION=1 ENABLE_FLASH_PERSISTENCE=1 ENABLE_FLASH_READONLY_PROBE=0
set_property generic $fs_generics [get_filesets sources_1]
puts "Persistence sources/VIO configured. No synthesis, implementation, bit or programming launched."
puts "User must check resource/timing/DRC, build and manually download matching bit/LTX."
puts "Hardware SAVE is EXPLICIT only; probe/reload/BtnC NEVER write flash."
