# Definitions only. MANUALLY call after a checked bit exists. No hardware API.
set ::rc_mcs_root [file normalize [file join [file dirname [info script]] ..]]
proc rc_create_boot_mcs {bit output} {
    set bit [file normalize $bit];set output [file normalize $output]
    set pending "${output}.pending.mcs";set report "${output}.audit.json"
    if {![file isfile $bit] || [file extension $bit] ne ".bit"} {error "Missing .bit"}
    foreach path [list $output $pending $report] {if {[file exists $path]} {error "Refusing to overwrite $path"}}
    set python [file join $::rc_mcs_root .venv-hds Scripts python.exe]
    if {![file isfile $python]} {error "Missing project Python for mandatory MCS audit"}
    # UG908/UG835: size is MiB, NOT Mbit. 32Mbit chip => 4MiB.
    # Standard SPI x1 boot image, from address zero only. No parameter payload.
    write_cfgmem -format mcs -interface SPIx1 -size 4 -loadbit [list up 0x0 $bit] -file $pending
    exec $python [file join $::rc_mcs_root scripts instruments audit_flash_mcs.py] \
        $pending --erase-size 65536 --report $report --bit $bit
    file rename $pending $output
    puts "AUDITED IMAGE: $output; manifest: $report"
    puts "Not programmed. Audit covers address ranges, NOT the programmer's erase policy."
    puts "Never Entire Device/chip erase; preserve 0x3E0000..0x3FFFFF and verify params after a manual upgrade."
    return $report
}
