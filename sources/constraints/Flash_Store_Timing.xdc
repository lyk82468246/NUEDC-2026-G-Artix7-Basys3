# Persistent SPI x1: clk_algo 100MHz, HALF_PERIOD=4, same proposed P1 budget.
# Actual external timing remains subject to the new implementation/board check.
# No blanket false paths. Fail closed if enabled hierarchy cannot be matched.
set fs_present [get_cells -quiet -hier -filter {NAME =~ *g_flash_persistent*}]
if {[llength $fs_present]>0} {
    set_property CONFIG_MODE SPIx1 [current_design]
    set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
    set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
    set fs_rx [get_cells -quiet -hier -filter {NAME =~ *g_flash_persistent*u_store*u_engine*u_byte*rx_reg*}]
    if {[llength $fs_rx]==0} {error "Persistent flash receive endpoint missing"}
    set fs_d [get_pins -quiet -of_objects $fs_rx -filter {REF_PIN_NAME == D}]
    if {[llength $fs_d]==0} {error "Persistent flash receive D pins missing"}
    set_max_delay -datapath_only 12.0 -from [get_ports flash_miso] -to $fs_d
    set_min_delay -datapath_only 0.0 -from [get_ports flash_miso] -to $fs_d
    foreach fs_pair {{mosi_reg flash_mosi} {cs_n_reg flash_cs_n}} {
        set fs_driver [get_cells -quiet -hier -filter "NAME =~ *g_flash_persistent*u_store*u_engine*u_byte*[lindex $fs_pair 0]*"]
        if {[llength $fs_driver]!=1} {error "Persistent flash output endpoint missing: $fs_pair"}
        set_max_delay -datapath_only 8.0 -from $fs_driver -to [get_ports [lindex $fs_pair 1]]
    }
}
