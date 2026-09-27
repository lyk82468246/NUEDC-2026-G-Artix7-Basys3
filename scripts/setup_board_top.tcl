#==============================================================================
# setup_board_top.tcl
#------------------------------------------------------------------------------
# Configure the Step 3 Basys 3 top level:
#   * Clocking Wizard (MMCM): 100 MHz + legal 12.2881356 MHz intermediate
#   * ILA: six probes clocked by the 100 MHz algorithm clock.  Probe 0 is the
#     self-consistent measurement-packet event; it is not the raw frame pulse.
#   * G_FPGA_Top RTL and Basys3_Pinout.xdc
#
# The 12.2881356 MHz MMCM output is divided by the Artix-7 BUFR /3 in
# MMCM_Top.v, yielding 4.0960452 MHz for AD9226.  A direct 4.096 MHz MMCM
# output is rejected by the Artix-7 Clocking Wizard minimum-frequency rule.
#
# Windows usage:
#   $env:PROCESSOR_ARCHITECTURE = 'AMD64'
#   $env:XILINX_LOCAL_USER_DATA = 'NO'
#   & 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch `
#     -nolog -nojournal -notrace `
#     -source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_board_top.tcl `
#     -tclargs C:/Users/Joe/Documents/Verilog/G_FPGA/G_FPGA.xpr
#==============================================================================

if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] < 1} {
        error "请通过 -tclargs 指定 G_FPGA.xpr。"
    }
    open_project [file normalize [lindex $argv 0]]
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set script_dir  [file normalize [file dirname [info script]]]
set rtl_dir     [file normalize [file join $project_dir sources rtl]]
set ip_dir      [file normalize [file join $project_dir sources ip]]
set xdc_dir     [file normalize [file join $project_dir sources constraints]]
set source_set  [get_filesets sources_1]
set constr_set  [get_filesets constrs_1]

file mkdir $rtl_dir
file mkdir $ip_dir
file mkdir $xdc_dir

proc add_file_once {fileset file_name} {
    set normalized [file normalize $file_name]
    if {[file exists $normalized] && [llength [get_files -quiet $normalized]] == 0} {
        add_files -norecurse -fileset $fileset $normalized
    }
}

foreach rtl_file [glob -nocomplain -directory $rtl_dir *.v] {
    add_file_once $source_set $rtl_file
}

set xdc_file [file normalize [file join $xdc_dir Basys3_Pinout.xdc]]
if {![file exists $xdc_file]} {
    error "找不到 Basys3 约束文件：$xdc_file"
}
add_file_once $constr_set $xdc_file

# Keep the project usable as a Basys 3 board project when the local board
# repository contains the Digilent definition.  The current Vivado installation
# may not have the board-store package, so the device part remains authoritative
# and the explicit XDC still provides every physical pin constraint.
set basys_board_part "digilentinc.com:basys3:part0:1.2"
set available_board_parts [get_board_parts -quiet $basys_board_part]
if {[llength $available_board_parts] > 0} {
    set_property board_part $basys_board_part [current_project]
    puts "INFO: board_part set to $basys_board_part"
} else {
    puts "WARNING: Basys 3 board definition is not installed in this Vivado instance; using xc7a35tcpg236-1 plus explicit XDC."
    set_property part xc7a35tcpg236-1 [current_project]
}

#--------------------------------------------------------------------------
# Clocking Wizard / MMCM
#--------------------------------------------------------------------------
set clk_name mmcm_top_wiz
set clk_ip [get_ips -quiet $clk_name]
if {[llength $clk_ip] == 0} {
    if {[catch {
        create_ip -name clk_wiz -vendor xilinx.com -library ip \
            -version 6.0 -module_name $clk_name -dir $ip_dir
    } create_clk_error]} {
        puts "WARNING: Clocking Wizard 6.0 creation failed: $create_clk_error"
        create_ip -name clk_wiz -vendor xilinx.com -library ip \
            -module_name $clk_name -dir $ip_dir
    }
    set clk_ip [get_ips $clk_name]
}

# These names and values were checked against Vivado 2025.2.  Setting the
# second output as used in the same transaction avoids disabled-parameter
# validation from silently ignoring the requested frequency.
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {12.2881356} \
    CONFIG.CLKOUT1_DRIVES {BUFG} \
    CONFIG.CLKOUT2_DRIVES {BUFG} \
    CONFIG.USE_RESET {true} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH} \
] $clk_ip

# The requested frequency deterministically selects M=7.250, VCO=725 MHz,
# CLKOUT0 divide=7.250 (100 MHz), and CLKOUT1 divide=59.  Print the resolved
# values so a future Vivado version cannot hide a different legal solution.
foreach clk_prop {CONFIG.MMCM_DIVCLK_DIVIDE CONFIG.MMCM_CLKFBOUT_MULT_F \
                  CONFIG.MMCM_CLKOUT0_DIVIDE_F CONFIG.MMCM_CLKOUT1_DIVIDE} {
    if {[lsearch -exact [list_property $clk_ip] $clk_prop] >= 0} {
        puts "INFO: $clk_prop = [get_property $clk_prop $clk_ip]"
    }
}

#--------------------------------------------------------------------------
# ILA: measurement-packet event, time-domain results, spectrum peak, UART FSM
# state. Probe 0 is generated after both time and peak results are snapshotted
# by HMI_UART_Ctrl, so the value probes describe the same measurement packet.
#--------------------------------------------------------------------------
set ila_name ila_system
set ila_ip [get_ips -quiet $ila_name]
if {[llength $ila_ip] == 0} {
    if {[catch {
        create_ip -name ila -vendor xilinx.com -library ip \
            -version 6.2 -module_name $ila_name -dir $ip_dir
    } create_ila_error]} {
        puts "WARNING: ILA 6.2 creation failed: $create_ila_error"
        create_ip -name ila -vendor xilinx.com -library ip \
            -module_name $ila_name -dir $ip_dir
    }
    set ila_ip [get_ips $ila_name]
}

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {6} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {16} \
    CONFIG.C_PROBE2_WIDTH {16} \
    CONFIG.C_PROBE3_WIDTH {31} \
    CONFIG.C_PROBE4_WIDTH {12} \
    CONFIG.C_PROBE5_WIDTH {5} \
    CONFIG.C_DATA_DEPTH {1024} \
] $ila_ip

foreach {ila_prop ila_value} {
    CONFIG.C_INPUT_PIPE_STAGES 1
    CONFIG.C_EN_STRG_QUAL 0
    CONFIG.C_ADV_TRIGGER false
    CONFIG.C_TRIGIN_EN false
    CONFIG.C_TRIGOUT_EN false
} {
    if {[lsearch -exact [list_property $ila_ip] $ila_prop] >= 0} {
        set_property $ila_prop $ila_value $ila_ip
    }
}

generate_target all [get_ips $clk_name]
generate_target all [get_ips $ila_name]

update_compile_order -fileset $source_set
set_property top G_FPGA_Top $source_set
update_compile_order -fileset $source_set

puts "INFO: Step 3 board top configured."
puts "INFO:   top       = G_FPGA_Top"
puts "INFO:   clock IP  = $clk_name (100 MHz + 12.2881356 MHz, wrapper /3 -> ADC clock)"
puts "INFO:   ILA       = $ila_name (6 probes, 1024 samples)"
puts "INFO:   constraints = $xdc_file"

close_project
