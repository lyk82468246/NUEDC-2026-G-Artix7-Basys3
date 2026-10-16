# Read-only supplementary checks on the implemented checkpoint; no bit rebuild.
# vivado -mode batch -source check_routed_signoff.tcl -tclargs FILE.dcp REPORT_DIR
if {[llength $argv] != 2} { error "Expected routed checkpoint and report directory" }
set checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $checkpoint]} { error "Missing checkpoint: $checkpoint" }
file mkdir $output_dir
open_checkpoint $checkpoint
report_bus_skew -file [file join $output_dir board_top_bus_skew.rpt]
report_route_status -file [file join $output_dir board_top_route_status.rpt]
check_timing -verbose -file [file join $output_dir board_top_check_timing.rpt]
report_cdc -details -file [file join $output_dir board_top_cdc.rpt]
report_methodology -file [file join $output_dir board_top_methodology.rpt]
close_design
