#==============================================================================
# impl_check_board_top.tcl
#------------------------------------------------------------------------------
# Run full synthesis and implementation for G_FPGA_Top, write reports and a
# bitstream, then fail if the worst setup slack is not positive.
#==============================================================================

if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] < 1} {
        error "请通过 -tclargs 指定 G_FPGA.xpr。"
    }
    open_project [file normalize [lindex $argv 0]]
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set script_dir  [file normalize [file dirname [info script]]]
set source_set  [get_filesets sources_1]
set synth_run   [get_runs -quiet synth_1]
set impl_run    [get_runs -quiet impl_1]

if {[llength [get_ips -quiet mmcm_top_wiz]] == 0 ||
    [llength [get_ips -quiet ila_system]] == 0 ||
    [llength [get_files -quiet [file join $project_dir sources constraints Basys3_Pinout.xdc]]] == 0 ||
    [llength [get_files -quiet [file join $project_dir sources rtl ADC_Input_CDC.v]]] == 0} {
    puts "INFO: board-top IP/constraint set is incomplete; sourcing setup_board_top.tcl"
    source [file join $script_dir setup_board_top.tcl]
    open_project [file normalize [lindex $argv 0]]
    set source_set [get_filesets sources_1]
    set synth_run  [get_runs -quiet synth_1]
    set impl_run   [get_runs -quiet impl_1]
}

if {[llength $synth_run] == 0 || [llength $impl_run] == 0} {
    error "工程缺少 synth_1 或 impl_1 运行配置。"
}

set_property top G_FPGA_Top $source_set
update_compile_order -fileset $source_set

reset_run $impl_run
reset_run $synth_run
launch_runs $synth_run -jobs 4
wait_on_run $synth_run
set synth_status [get_property STATUS $synth_run]
puts "INFO: synth_1 status = $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "G_FPGA_Top 综合失败：$synth_status"
}

launch_runs $impl_run -to_step write_bitstream -jobs 4
wait_on_run $impl_run
set impl_status [get_property STATUS $impl_run]
puts "INFO: impl_1 status = $impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "G_FPGA_Top 实现/比特流生成失败：$impl_status"
}

set report_dir [file join $project_dir reports]
file mkdir $report_dir
open_run $impl_run
report_utilization -file [file join $report_dir board_top_utilization.rpt]
report_timing_summary -file [file join $report_dir board_top_timing.rpt]
report_io -file [file join $report_dir board_top_io.rpt]
report_drc -file [file join $report_dir board_top_drc.rpt]
report_clocks -file [file join $report_dir board_top_clocks.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths  [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths] > 0} {
    set wns [get_property SLACK [lindex $setup_paths 0]]
} else {
    set wns "NA"
}
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
} else {
    set whs "NA"
}
puts "INFO: WNS = $wns ns"
puts "INFO: WHS = $whs ns"

if {$wns eq "NA" || $wns <= 0.0} {
    close_design
    error "时序不满足：要求 WNS > 0 ns，实际 WNS = $wns ns。"
}

close_design
close_project
puts "INFO: Step 3 synthesis and implementation passed with WNS > 0 ns."
