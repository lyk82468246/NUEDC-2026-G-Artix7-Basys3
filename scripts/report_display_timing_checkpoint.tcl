# READ-ONLY analysis of the user's EXISTING routed checkpoint. Batch only.
# Does not open/save the GUI project, synthesize, place, route, generate IP/bit,
# or program hardware. Reports describe the OLD netlist, not edited RTL.
set dt_root [file normalize [file join [file dirname [info script]] ..]]
set dt_dcp [file join $dt_root G_FPGA.runs impl_1 G_FPGA_Top_routed.dcp]
if {![file exists $dt_dcp]} {error "No existing routed checkpoint: $dt_dcp"}
set dt_reports [file join $dt_root reports display_timing_20261030]
file mkdir $dt_reports
open_checkpoint $dt_dcp
report_timing -delay_type max -max_paths 100 -nworst 1 -slack_lesser_than 0 \
    -file [file join $dt_reports before_worst100.rpt]
set dt_out [open [file join $dt_reports before_worst100.tsv] w]
puts $dt_out "slack_ns\tsource\tdestination"
foreach dt_path [get_timing_paths -delay_type max -max_paths 100 -nworst 1 -slack_lesser_than 0] {
    puts $dt_out "[get_property SLACK $dt_path]\t[get_property STARTPOINT_PIN $dt_path]\t[get_property ENDPOINT_PIN $dt_path]"
}
close $dt_out
close_design
exit
