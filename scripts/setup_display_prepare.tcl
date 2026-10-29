# Registration only. No top/generic/IP/run/program/clock changes.
# New modules are intentionally NOT instantiated in the working board top.
if {[llength [get_projects -quiet]]==0} {error "Open the existing GUI project first"}
set dp_root [file normalize [file join [file dirname [info script]] ..]]
if {[file normalize [get_property DIRECTORY [current_project]]] ne $dp_root} {error "Wrong project"}
foreach dp_name {Display_Unsigned_Divider Display_Frame_Calibrator Display_Wave_Renderer Display_Spectrum_Renderer Display_mV_Formatter} {
    set dp_path [file join $dp_root sources rtl ${dp_name}.v]
    if {![file exists $dp_path]} {error "Missing display preparation source: $dp_path"}
    if {[llength [get_files -quiet $dp_path]]==0} {add_files -fileset sources_1 -norecurse $dp_path}
    foreach dp_usage {USED_IN_SYNTHESIS USED_IN_IMPLEMENTATION USED_IN_SIMULATION} {
        set_property $dp_usage true [get_files $dp_path]
    }
}
puts "Display preparation sources registered only. Current top/datapath/IP unchanged; no build required now."
