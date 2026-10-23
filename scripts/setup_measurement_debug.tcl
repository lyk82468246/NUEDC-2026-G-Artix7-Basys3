# User GUI: source this script before manually synthesizing the new top.
# Registers only the read-only sidecar and regenerates only ILA products.
# Never touches FIR/MMCM/VIO properties or launches any build/program/reset.
if {[llength [get_projects -quiet]]==0} {error "Open the existing G_FPGA GUI project first"}
set md_root [file normalize [file join [file dirname [info script]] ..]]
if {[file normalize [get_property DIRECTORY [current_project]]] ne $md_root} {error "Wrong project"}
set md_file [file join $md_root sources rtl Measurement_Debug_Snapshot.v]
if {[llength [get_files -quiet $md_file]]==0} {add_files -fileset sources_1 -norecurse $md_file}
set_property USED_IN_SYNTHESIS true [get_files $md_file]
set_property USED_IN_IMPLEMENTATION true [get_files $md_file]
set_property USED_IN_SIMULATION true [get_files $md_file]
set md_ip [get_ips -quiet ila_system]
if {[llength $md_ip]!=1} {error "Expected existing ila_system"}
source [file join $md_root scripts measurement_debug_ila_config.tcl]
configure_measurement_debug_ila $md_ip
generate_target all $md_ip
puts "Debug snapshot configured: 15 probes / 1024 samples. Save project; manually build and check timing/DRC."
puts "New bit AND matching new LTX required. No build or programming performed. FIR/VIO unchanged."
