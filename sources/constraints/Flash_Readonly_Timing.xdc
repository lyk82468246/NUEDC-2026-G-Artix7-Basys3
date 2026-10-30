# SPI x1 receive/drive budget, clk=sys_clk=100MHz, HALF_PERIOD=4 (40ns).
# MX25L3233F tCLQV <=8ns at 30pF. Reserve CCLK pad/board/setup margin;
# cap MISO pad->sample-register path at 12ns, CS/MOSI register->pad at 8ns.
# SCK is a CE-generated output waveform, not a continuously generated clock.
# No blanket false-path or fabricated periodic generated-clock relationship.
# This is a bounded datapath budget; real pad/board SCK/MISO relationship must
# still be checked on the read-only board test and in the implementation report.
set fp_present [get_cells -quiet -hier -filter {NAME =~ *g_flash_readonly*}]
set fp_rx [get_cells -quiet -hier -filter {NAME =~ *g_flash_readonly*u_probe*u_restore*u_reader*u_byte*rx_reg*}]
if {[llength $fp_present]>0} {
    if {[llength $fp_rx]==0} {error "Enabled Flash probe receive path missing; timing constraints not applied"}
    set fp_rx_d [get_pins -quiet -of_objects $fp_rx -filter {REF_PIN_NAME == D}]
    if {[llength $fp_rx_d]==0} {error "Flash receive register endpoint missing"}
    set_max_delay -datapath_only 12.0 -from [get_ports flash_miso] -to $fp_rx_d
    set_min_delay -datapath_only 0.0 -from [get_ports flash_miso] -to $fp_rx_d
    foreach fp_pair {{mosi_reg flash_mosi} {cs_n_reg flash_cs_n}} {
        set fp_driver [get_cells -quiet -hier -filter "NAME =~ *g_flash_readonly*u_probe*u_restore*u_reader*u_byte*[lindex $fp_pair 0]*"]
        if {[llength $fp_driver]!=1} {error "Flash output register endpoint missing: $fp_pair"}
        set_max_delay -datapath_only 8.0 -from $fp_driver -to [get_ports [lindex $fp_pair 1]]
    }
}
