#==============================================================================
# synth_check_capture_calc.tcl
#------------------------------------------------------------------------------
# 对本阶段临时顶层 Capture_Calc_Subsystem 做一次 Vivado 综合检查。
# 用法：
#   vivado.bat -mode batch \
#     -source scripts/synth_check_capture_calc.tcl -tclargs G_FPGA.xpr
#==============================================================================

if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] < 1} {
        error "请通过 -tclargs 指定 G_FPGA.xpr。"
    }
    open_project [file normalize [lindex $argv 0]]
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set source_set  [get_filesets sources_1]
set synth_run  [get_runs -quiet synth_1]

if {[llength $synth_run] == 0} {
    error "当前工程没有 synth_1 运行配置。"
}

set_property top Capture_Calc_Subsystem $source_set
update_compile_order -fileset $source_set

# 只重置本阶段综合运行产生的结果，不修改 RTL/IP 源文件。
reset_run $synth_run
launch_runs $synth_run -jobs 4
wait_on_run $synth_run

set synth_status [get_property STATUS $synth_run]
puts "INFO: synth_1 status = $synth_status"

if {![string match "*Complete*" $synth_status] &&
    [get_property STATE $synth_run] ne "synthesized"} {
    error "Capture_Calc_Subsystem 综合失败，状态为：$synth_status"
}

set report_dir [file join $project_dir reports]
file mkdir $report_dir
open_run $synth_run
report_utilization -file [file join $report_dir capture_calc_utilization.rpt]
report_timing_summary -file [file join $report_dir capture_calc_timing.rpt]
close_design

puts "INFO: 综合检查通过。报告目录：$report_dir"
close_project
