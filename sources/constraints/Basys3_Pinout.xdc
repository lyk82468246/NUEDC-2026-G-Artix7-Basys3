##==============================================================================
## Basys3_Pinout.xdc
## Board configuration Flash SPI x1 (Digilent Basys-3 Master.xdc, rev B).
## CCLK uses STARTUPE2; never assign a normal package pin to it.
##------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33} [get_ports flash_cs_n]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports flash_mosi]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports flash_miso]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports flash_wp_n]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports flash_hold_n]
## Basys 3 rev B package pin assignments, based on Digilent's Basys-3 Master
## XDC.  The AD9226 bus is intentionally assigned in connector order:
##
##   ADC clock       JB1  A14
##   adc_data_in[0] JB2  A16
##   adc_data_in[1] JB3  B15
##   adc_data_in[2] JB4  B16
##   adc_data_in[3] JB7  A15
##   adc_data_in[4] JB8  A17
##   adc_data_in[5] JB9  C15
##   adc_data_in[6] JB10 C16
##   adc_data_in[7] JC1  K17
##   adc_data_in[8] JC2  M18
##   adc_data_in[9] JC3  N17
##   adc_data_in[10] JC4 P18
##   adc_data_in[11] JC7 L17
##
## Confirm the AD9226 module's logic supply and ground before connecting it to
## the 3.3 V Basys 3 PMOD banks.  The ADC output timing constraints below are
## deliberately modest placeholders; refine them with the exact AD9226 grade,
## clock edge, and PCB delay from its datasheet/board.
##==============================================================================

## 100 MHz system clock
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports sys_clk]

## Buttons: BtnC = U18, BtnU = T18
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports key_cycle]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports key_down]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports key_left]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports key_right]

## Board controls/display: official Digilent Basys-3-Master.xdc mapping.
## Only SW0..3 and SW15 affect control; others are reserved inputs.
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN W2 IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {sw[15]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led[15]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[0]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[1]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[2]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[3]}]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[4]}]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[5]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {seg[6]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {an[0]}]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {an[1]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {an[2]}]
set_property -dict {PACKAGE_PIN W4 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {an[3]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports dp]

## UART display TX: JA1 / J1
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports uart_tx]

## AD9226 forwarded sample clock: JB1 / A14
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST} [get_ports adc_clk_out]

## AD9226 12-bit parallel data bus
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[0]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[1]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[2]}]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[3]}]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[4]}]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[5]}]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[6]}]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[7]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[8]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[9]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[10]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports {adc_data_in[11]}]

## FPGA configuration defaults recommended for Basys 3
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## The Clocking Wizard and BUFR generate the internal clocks.  The wizard's
## generated clock constraint creates the primary clock and its MMCM-derived
## clocks; attach AD9226 input timing to the final divided ADC clock.
set_input_delay -clock [get_clocks -of_objects [get_pins -hierarchical *u_adc_clock_bufr/O]] -max 8.0 [get_ports adc_data_in[*]]
set_input_delay -clock [get_clocks -of_objects [get_pins -hierarchical *u_adc_clock_bufr/O]] -min 0.0 [get_ports adc_data_in[*]]

## The ADC bus is a bundled-data toggle CDC.  adc_data_hold is guaranteed to
## remain unchanged from the source toggle until the destination observes the
## synchronized toggle; it is therefore not a synchronous path between the
## related BUFR and 100 MHz clocks.  A clock-level exception is used here so
## Vivado sees the intended CDC exception in both synthesis and implementation
## netlists (pin names can be optimized away before XDC application).  Input
## delay checks from the external AD9226 to the source capture flops remain
## active because they are constrained above against clk_adc.
set_false_path -from [get_clocks clk_adc] \
               -to   [get_clocks clk_out1_mmcm_top_wiz]
