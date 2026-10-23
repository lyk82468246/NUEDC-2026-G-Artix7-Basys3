# Source in the user's OPEN GUI project. Registration/IP generation only:
# NEVER launches synthesis, implementation, bit generation or programming.
if {[llength [get_projects -quiet]]!=1} {error "Open G_FPGA project in GUI first"}
set rc_root [file normalize [file join [file dirname [info script]] ..]]
if {[file normalize [get_property DIRECTORY [current_project]]] ne $rc_root} {
    error "Current project directory differs from script workspace"
}
set rc_file [file join $rc_root sources rtl Runtime_Calibration.v]
if {[llength [get_files -quiet $rc_file]]==0} {add_files -fileset sources_1 -norecurse $rc_file}
set_property USED_IN_SYNTHESIS true [get_files $rc_file]
set rc_ip [get_ips -quiet vio_calibration]
if {[llength $rc_ip]==0} {
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
        -module_name vio_calibration -dir [file join $rc_root sources ip]
    set rc_ip [get_ips vio_calibration]
}
set rc_props [list CONFIG.C_NUM_PROBE_IN 11 CONFIG.C_NUM_PROBE_OUT 5]
foreach {n w} {0 1 1 32 2 32 3 32 4 8 5 32 6 32 7 32 8 32 9 32 10 32} {
    lappend rc_props CONFIG.C_PROBE_IN${n}_WIDTH $w
}
foreach {n w} {0 32 1 32 2 32 3 1 4 1} {
    lappend rc_props CONFIG.C_PROBE_OUT${n}_WIDTH $w CONFIG.C_PROBE_OUT${n}_INIT_VAL 0x0
}
set_property -dict $rc_props $rc_ip
generate_target all $rc_ip
# Preserve existing generic overrides, replace only this one.
set rc_generics {}
foreach rc_generic [get_property generic [get_filesets sources_1]] {
    if {![string match ENABLE_RUNTIME_CALIBRATION=* $rc_generic]} {lappend rc_generics $rc_generic}
}
lappend rc_generics ENABLE_RUNTIME_CALIBRATION=1
set_property generic $rc_generics [get_filesets sources_1]
puts "Runtime calibration registered/enabled. User must manually build and program new bit+LTX."
puts "All gains and calibration-valid initialize to zero. Existing ILA and raw HMI unchanged."
