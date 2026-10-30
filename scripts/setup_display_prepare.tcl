# Registration only. No top/generic/IP/run/program/clock changes.
# Display_HMI is now instantiated by the board top (ENABLE_DISPLAY=1).
if {[llength [get_projects -quiet]]==0} {error "Open the existing GUI project first"}
set dp_root [file normalize [file join [file dirname [info script]] ..]]
if {[file normalize [get_property DIRECTORY [current_project]]] ne $dp_root} {error "Wrong project"}
set dp_names {Display_Unsigned_Divider Display_Frame_Calibrator Display_Sine_ROM Display_Fundamental_Aligner Display_Interpolation_ROM Display_Bandlimited_Interpolator Display_Wave_Renderer Display_Spectrum_Renderer Display_mV_Formatter Display_UART_Command Display_HMI}
# Preflight every path before mutating the open project's in-memory source set.
foreach dp_name $dp_names {
    set dp_path [file join $dp_root sources rtl ${dp_name}.v]
    if {![file exists $dp_path]} {error "Missing display preparation source: $dp_path"}
}
foreach dp_name $dp_names {
    set dp_path [file join $dp_root sources rtl ${dp_name}.v]
    if {![file exists $dp_path]} {error "Missing display preparation source: $dp_path"}
    if {[llength [get_files -quiet $dp_path]]==0} {add_files -fileset sources_1 -norecurse $dp_path}
    foreach dp_usage {USED_IN_SYNTHESIS USED_IN_IMPLEMENTATION USED_IN_SIMULATION} {
        set_property $dp_usage true [get_files $dp_path]
    }
}
foreach dp_name $dp_names {
    set dp_path [file join $dp_root sources rtl ${dp_name}.v]
    if {[llength [get_files -quiet $dp_path]]!=1} {error "Source registration failed: $dp_path"}
    puts "REGISTERED: $dp_name (synthesis / implementation / simulation)"
}
puts "Display sources registered. No build launched. Manually rebuild/program to activate the new display RTL."
