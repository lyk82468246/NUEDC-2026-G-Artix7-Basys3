# GUI-only explicit selection; sourcing defines procedures and changes NOTHING.
# fir_eq_select experimental : modeled 95-tap symmetric amplitude equalizer
# fir_eq_select baseline     : original 95-tap low-pass from production COE
# Generates IP output products only. NEVER launches synthesis/implementation,
# bit generation, reset or programming. User must manually build + verify.
namespace eval fir_eq {
    variable root [file normalize [file join [file dirname [info script]] ..]]
}
proc fir_eq::property {ip names} {
    foreach name $names {
        if {$name in [list_property $ip]} {return $name}
    }
    error "Missing required FIR property: $names"
}
proc fir_eq_select {mode} {
    if {$mode ni {experimental baseline}} {error "Choose experimental or baseline explicitly"}
    if {[llength [get_projects -quiet]]!=1} {error "Open GUI project first"}
    set root $fir_eq::root
    if {[file normalize [get_property DIRECTORY [current_project]]] ne $root} {
        error "Current project is not this workspace"
    }
    set ip [get_ips -quiet fir_compiler_lp_600k]
    if {[llength $ip]!=1} {error "Expected existing fir_compiler_lp_600k"}
    # Check every format assumption BEFORE any project mutation.
    foreach {names expected} {
        {CONFIG.Coefficient_Width CONFIG.coefficient_width} 16
        {CONFIG.Coefficient_Fractional_Bits CONFIG.coefficient_fractional_bits} 15
        {CONFIG.Coefficient_Sign CONFIG.coefficient_sign} Signed
        {CONFIG.BestPrecision CONFIG.bestprecision} false
        {CONFIG.Quantization CONFIG.quantization} Quantize_Only
        {CONFIG.Coefficient_Sets CONFIG.coefficient_sets} 1
        {CONFIG.Coefficient_Reload CONFIG.coefficient_reload} false
        {CONFIG.Filter_Type CONFIG.filter_type} Single_Rate
        {CONFIG.Data_Width CONFIG.data_width} 16
        {CONFIG.Data_Fractional_Bits CONFIG.data_fractional_bits} 0
        {CONFIG.Output_Width CONFIG.output_width} 16
        {CONFIG.Output_Rounding_Mode CONFIG.output_rounding_mode} Truncate_LSBs
    } {
        set prop [fir_eq::property $ip $names]
        set actual [get_property $prop $ip]
        if {$expected eq "false" && [string is boolean -strict $actual]} {
            set actual [expr {$actual ? "true" : "false"}]
        }
        if {![string equal -nocase $actual $expected]} {
            error "FIR format differs: $prop; inspect before using this experiment"
        }
    }
    if {$mode eq "experimental"} {
        set source [file join $root docs equalization_study_20261023 amplitude_only_95t_q15.coe]
    } else {
        set source [file join $root sources coeffs fir_lp_600k_95t.coe]
    }
    set stream [open $source r];set text [read $stream];close $stream
    if {![regexp {memory_initialization_radix\s*=\s*10\s*;} $text] ||
        ![regexp {memory_initialization_vector\s*=\s*([^;]+);} $text unused vector]} {
        error "Invalid decimal COE"
    }
    set coefficients {};set quantized {};set sum 0
    foreach value [split $vector ,] {
        set value [string trim $value]
        if {![regexp {^-?[0-9]+\.[0-9]+$} $value]} {error "Invalid coefficient"}
        set q [expr {round(double($value)*32768.0)}]
        if {$q < -32768 || $q > 32767} {error "Coefficient outside Q1.15"}
        lappend coefficients $value;lappend quantized $q;incr sum $q
    }
    if {[llength $coefficients]!=95} {error "Expected exactly 95 coefficients"}
    for {set i 0} {$i<47} {incr i} {
        if {[lindex $quantized $i]!=[lindex $quantized [expr {94-$i}]]} {
            error "Only symmetric candidate is authorized by this experiment script"
        }
    }
    set psource [fir_eq::property $ip {CONFIG.Coefficient_Source CONFIG.CoefficientSource CONFIG.coefficientsource}]
    set pvector [fir_eq::property $ip {CONFIG.CoefficientVector CONFIG.coefficientvector}]
    set_property -dict [list $psource Vector $pvector [join $coefficients ,]] $ip
    generate_target all $ip
    puts "FIR selection=$mode, 95 signed Q1.15 taps, sum=$sum. Production COE unchanged."
    puts "Manually inspect IP symmetry, save GUI project, build/route/check timing, generate bit+LTX."
    puts "EXPERIMENTAL MODEL ONLY: no absolute voltage, phase or general C-mode acceptance."
    return [dict create mode $mode coefficient_count 95 sum_q15 $sum source $source]
}
