# Run in a FRESH Vivado batch process (non-project flow), before the board build.
# vivado -mode batch -source refresh_ila_checkpoint.tcl -tclargs /path/ila_system.xci
# Optional second argument "check" validates configuration without regeneration.
if {[llength $argv]<1 || [llength $argv]>2} {error "Expected ILA.xci and optional check"}
set check_only 0
if {[llength $argv]==2} {
    if {[lindex $argv 1] ne "check"} {error "Second argument must be check"}
    set check_only 1
}
if {[llength [get_projects -quiet]]!=0} {error "Use a fresh non-project Vivado process"}
set xci [file normalize [lindex $argv 0]]
if {![file isfile $xci]} {error "Missing ILA XCI: $xci"}
set_part xc7a35tcpg236-1
read_ip $xci
set ip [get_ips ila_system]
foreach {property expected} {
    CONFIG.C_NUM_OF_PROBES 10 CONFIG.C_DATA_DEPTH 1024
    CONFIG.C_PROBE0_WIDTH 1 CONFIG.C_PROBE1_WIDTH 16
    CONFIG.C_PROBE2_WIDTH 16 CONFIG.C_PROBE3_WIDTH 31
    CONFIG.C_PROBE4_WIDTH 12 CONFIG.C_PROBE5_WIDTH 5
    CONFIG.C_PROBE6_WIDTH 32 CONFIG.C_PROBE7_WIDTH 12
    CONFIG.C_PROBE8_WIDTH 36 CONFIG.C_PROBE9_WIDTH 32
} {
    if {[get_property $property $ip] != $expected} {error "Unexpected $property"}
}
if {!$check_only} {
    set_property GENERATE_SYNTH_CHECKPOINT true [get_files $xci]
    synth_ip -force $ip
    if {![file isfile [file join [file dirname $xci] ila_system.dcp]]} {
        error "ILA checkpoint was not generated"
    }
}
puts "PASS: ILA non-project checkpoint flow (check_only=$check_only)"
