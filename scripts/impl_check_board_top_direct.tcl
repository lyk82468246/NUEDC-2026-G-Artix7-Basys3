#==============================================================================
# impl_check_board_top_direct.tcl
#------------------------------------------------------------------------------
# Project-mode synthesis/implementation flow used by
# run_impl_check_windows.cmd.
#
# Vivado normally launches project runs through runme.bat, which delegates to
# Windows Script Host (cscript).  On some managed Windows installations that
# host cannot load its per-user settings and the run stops before Vivado is
# started.  This script performs the same design stages in one Vivado process,
# so the result is independent of cscript/vrs.
#==============================================================================

if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] < 1} {
        error "请通过 -tclargs 指定 G_FPGA.xpr。"
    }
    open_project [lindex $argv 0]
}

set project       [current_project]
set project_dir   [file normalize [get_property DIRECTORY $project]]
set source_set   [get_filesets sources_1]
set constr_set   [get_filesets constrs_1]
set part_name    [get_property PART $project]
set report_dir   [file join $project_dir reports]
set impl_dir     [file join $project_dir G_FPGA.runs impl_1]

if {$part_name eq ""} {
    set part_name xc7a35tcpg236-1
    set_property part $part_name $project
}

file mkdir $report_dir
file mkdir $impl_dir

puts "INFO: direct flow project = $project_dir"
puts "INFO: direct flow part    = $part_name"

set_property top G_FPGA_Top $source_set
update_compile_order -fileset $source_set

# Make sure all XCI output products are present before the standalone
# synth_design command consumes the project fileset.
set project_ips [get_ips -quiet]
if {[llength $project_ips] > 0} {
    puts "INFO: generating [llength $project_ips] IP output products"
    generate_target all $project_ips
}

# Project-mode synth_design does not automatically execute every XDC in the
# project fileset when it is invoked manually.  Read the active constraints
# explicitly so both synthesis and implementation see the board pinout,
# generated clocks, and ADC timing assumptions.
set xdc_files [get_files -quiet -of_objects $constr_set]
foreach xdc_file $xdc_files {
    if {[file exists $xdc_file]} {
        puts "INFO: reading XDC $xdc_file"
        read_xdc $xdc_file
    }
}

puts "INFO: synth_design started"
synth_design -top G_FPGA_Top -part $part_name -flatten_hierarchy rebuilt
write_checkpoint -force [file join $impl_dir G_FPGA_Top_synth.dcp]
report_utilization -file [file join $report_dir board_top_utilization_synth.rpt]
report_timing_summary -file [file join $report_dir board_top_timing_synth.rpt]

puts "INFO: opt_design started"
opt_design

puts "INFO: place_design started"
place_design

puts "INFO: phys_opt_design started"
phys_opt_design

puts "INFO: route_design started"
route_design
write_checkpoint -force [file join $impl_dir G_FPGA_Top_routed.dcp]

puts "INFO: generating bitstream"
set bit_file [file join $impl_dir G_FPGA_Top.bit]
write_bitstream -force $bit_file

# The ILA debug probe file is generated alongside the bitstream.  It is
# required by Vivado Hardware Manager to decode the probes in the programmed
# device.
set ltx_file [file join $impl_dir G_FPGA_Top.ltx]
if {[llength [get_debug_cores -quiet]] > 0} {
    write_debug_probes -force $ltx_file
}

report_utilization -file [file join $report_dir board_top_utilization.rpt]
report_timing_summary -file [file join $report_dir board_top_timing.rpt]
report_io -file [file join $report_dir board_top_io.rpt]
report_drc -file [file join $report_dir board_top_drc.rpt]
report_clocks -file [file join $report_dir board_top_clocks.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1 -quiet]
set hold_paths  [get_timing_paths -delay_type min -max_paths 1 -quiet]
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
puts "INFO: bitstream = $bit_file"
puts "INFO: probes    = $ltx_file"

if {$wns eq "NA" || $wns <= 0.0} {
    error "时序不满足：要求 WNS > 0 ns，实际 WNS = $wns ns。"
}

puts "INFO: direct synthesis, implementation, timing, bitstream and ILA generation passed."

