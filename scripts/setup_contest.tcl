# Register the implemented P2 board-control RTL. Does not build or program.
# Usage: vivado -mode batch -source scripts/setup_contest.tcl -tclargs G_FPGA.xpr
if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] != 1} {error "Expected project .xpr path"}
    open_project [file normalize [lindex $argv 0]]
}
set contest_root [file normalize [get_property DIRECTORY [current_project]]]
foreach contest_name {Switch_Filter Run_Controller SevenSeg_Scan Board_Status_Display} {
    set contest_path [file join $contest_root sources rtl ${contest_name}.v]
    if {![file exists $contest_path]} {error "Missing RTL: $contest_path"}
    if {[llength [get_files -quiet $contest_path]] == 0} {
        add_files -fileset sources_1 -norecurse $contest_path
    }
}
# P3 Component_Analyzer/Measurement_Calibrator remain standalone test subjects;
# do not imply that they replace the production Peak_Search yet.
set_property top G_FPGA_Top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "P2 source registration complete; no synthesis or programming performed."
