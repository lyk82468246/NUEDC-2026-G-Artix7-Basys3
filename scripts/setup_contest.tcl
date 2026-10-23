# Register P2 board controls and the P3 component analyzer. No build/program.
# In the user's OPEN GUI project: source /absolute/path/scripts/setup_contest.tcl
# Does not reset/launch runs, regenerate IP, close the GUI project, or program.
# Batch registration-only usage also accepts -tclargs G_FPGA.xpr.
if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] != 1} {error "Expected project .xpr path"}
    open_project [file normalize [lindex $argv 0]]
}
set contest_root [file normalize [get_property DIRECTORY [current_project]]]
foreach contest_name {Switch_Filter Run_Controller SevenSeg_Scan Board_Status_Display Component_Analyzer Measurement_Debug_Snapshot} {
    set contest_path [file join $contest_root sources rtl ${contest_name}.v]
    if {![file exists $contest_path]} {error "Missing RTL: $contest_path"}
    if {[llength [get_files -quiet $contest_path]] == 0} {
        add_files -fileset sources_1 -norecurse $contest_path
    }
    set contest_file [get_files -quiet $contest_path]
    if {[llength $contest_file]!=1} {error "Expected exactly one source: $contest_name"}
    set_property USED_IN_SYNTHESIS true $contest_file
    set_property USED_IN_IMPLEMENTATION true $contest_file
    set_property USED_IN_SIMULATION true $contest_file
}
# Controlled board top now uses Component_Analyzer; legacy subsystem tests keep
# Peak_Search. Measurement_Calibrator remains standalone, no guessed mV gains.
set_property top G_FPGA_Top [get_filesets sources_1]
update_compile_order -fileset sources_1
set contest_compile_files [get_files -compile_order sources -used_in synthesis -of_objects [get_filesets sources_1]]
set contest_found 0
foreach contest_file $contest_compile_files {
    if {[file tail $contest_file] eq "Component_Analyzer.v"} {set contest_found 1}
}
if {!$contest_found} {error "Component_Analyzer is missing from synthesis compile order"}
puts "PASS: Component_Analyzer registered, enabled, and included in synthesis compile order."
puts "P2/P3 source registration complete; no synthesis or programming performed."
