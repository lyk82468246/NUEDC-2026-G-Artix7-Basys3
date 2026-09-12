#==============================================================================
# setup_fft_uart.tcl
#------------------------------------------------------------------------------
# 为 Step 2 配置并生成：
#   1) xfft_8192          - 8192 点 Radix-4 Burst I/O FFT
#   2) cordic_translate_mag - Translate 模式复数幅值计算
#   3) flat_top_window_rom  - 8192 x 16-bit Block Memory ROM
#
# 用法（Windows PowerShell）：
#   $env:PROCESSOR_ARCHITECTURE = 'AMD64'
#   $env:XILINX_LOCAL_USER_DATA = 'NO'
#   & 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch `
#       -nolog -nojournal -notrace `
#       -source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_fft_uart.tcl `
#       -tclargs C:/Users/Joe/Documents/Verilog/G_FPGA/G_FPGA.xpr
#
# 脚本既可以在已打开的 G_FPGA 工程中 source，也可以在 batch 模式下通过
# -tclargs 传入 xpr。若第一阶段的 FIR/CORDIC IP 尚未存在，会自动 source
# setup_capture_calc.tcl 先补齐依赖。
#==============================================================================

if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] < 1} {
        error "请先打开 G_FPGA.xpr，或以 -tclargs G_FPGA.xpr 运行本脚本。"
    }
    open_project [file normalize [lindex $argv 0]]
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set script_dir  [file normalize [file dirname [info script]]]
set rtl_dir     [file normalize [file join $project_dir sources rtl]]
set coeff_dir   [file normalize [file join $project_dir sources coeffs]]
set ip_dir      [file normalize [file join $project_dir sources ip]]
set source_set  [get_filesets sources_1]

file mkdir $rtl_dir
file mkdir $coeff_dir
file mkdir $ip_dir

# 将一个属性设置到第一个存在的候选名上。对关键属性不存在的情况直接报错，
# 防止 Vivado 版本差异导致 IP 悄悄落回默认配置。
proc set_required_property {obj candidates value} {
    set available [list_property $obj]
    foreach prop $candidates {
        if {[lsearch -exact $available $prop] >= 0} {
            set_property $prop $value $obj
            return $prop
        }
    }
    error "IP [get_property NAME $obj] 不支持必要属性 $candidates，无法安全继续。"
}

# 非关键属性在不同 Vivado/IP 小版本中可能不存在，缺失时只提示。
proc set_optional_property {obj candidates value} {
    set available [list_property $obj]
    foreach prop $candidates {
        if {[lsearch -exact $available $prop] >= 0} {
            set_property $prop $value $obj
            return $prop
        }
    }
    puts "INFO: IP [get_property NAME $obj] 跳过可选属性 $candidates"
    return ""
}

proc add_file_once {fileset file_name} {
    set normalized [file normalize $file_name]
    if {[llength [get_files -quiet $normalized]] == 0} {
        add_files -norecurse -fileset $fileset $normalized
    }
}

#--------------------------------------------------------------------------
# 检查/补齐第一阶段依赖
#--------------------------------------------------------------------------
set missing_first_stage 0
foreach required_ip {fir_compiler_lp_600k cordic_sqrt_rms} {
    if {[llength [get_ips -quiet $required_ip]] == 0} {
        set missing_first_stage 1
    }
}

if {$missing_first_stage} {
    set capture_setup [file join $script_dir setup_capture_calc.tcl]
    if {![file exists $capture_setup]} {
        error "缺少第一阶段 IP，且找不到 $capture_setup。"
    }
    puts "INFO: 第一阶段 IP 不完整，自动运行 setup_capture_calc.tcl。"
    source $capture_setup
}

#--------------------------------------------------------------------------
# RTL 与 COE
#--------------------------------------------------------------------------
foreach rtl_file [glob -nocomplain -directory $rtl_dir *.v] {
    add_file_once $source_set $rtl_file
}

set coe_file [file normalize [file join $coeff_dir flat_top_window_8192.coe]]
if {![file exists $coe_file]} {
    error "找不到 $coe_file；请先运行：python scripts/generate_flattop.py"
}
add_file_once $source_set $coe_file

#--------------------------------------------------------------------------
# Xilinx FFT 9.1：8192 点、Radix-4 Burst、Fixed Point、Unscaled
#--------------------------------------------------------------------------
set fft_name xfft_8192
set fft_ip [get_ips -quiet $fft_name]
if {[llength $fft_ip] == 0} {
    if {[catch {
        create_ip -name xfft -vendor xilinx.com -library ip \
            -version 9.1 -module_name $fft_name -dir $ip_dir
    } create_fft_error]} {
        puts "WARNING: XFFT 9.1 创建失败：$create_fft_error"
        puts "WARNING: 尝试使用 IP Catalog 中的默认 XFFT 版本。"
        create_ip -name xfft -vendor xilinx.com -library ip \
            -module_name $fft_name -dir $ip_dir
    }
    set fft_ip [get_ips $fft_name]
}

set_required_property $fft_ip {CONFIG.transform_length} 8192
set_required_property $fft_ip {CONFIG.implementation_options} radix_4_burst_io
set_required_property $fft_ip {CONFIG.data_format} fixed_point
set_required_property $fft_ip {CONFIG.input_width} 16
set_required_property $fft_ip {CONFIG.scaling_options} unscaled
set_required_property $fft_ip {CONFIG.output_ordering} natural_order
set_required_property $fft_ip {CONFIG.run_time_configurable_transform_length} false
set_required_property $fft_ip {CONFIG.throttle_scheme} nonrealtime
set_required_property $fft_ip {CONFIG.aresetn} true
set_optional_property $fft_ip {CONFIG.target_clock_frequency} 100
set_optional_property $fft_ip {CONFIG.rounding_modes} truncation
set_optional_property $fft_ip {CONFIG.ovflo} false
set_optional_property $fft_ip {CONFIG.xk_index} false

#--------------------------------------------------------------------------
# CORDIC 6.0：Translate，SignedFraction，30-bit 输入 -> 31-bit 幅值输出
#--------------------------------------------------------------------------
set cordic_name cordic_translate_mag
set cordic_ip [get_ips -quiet $cordic_name]
if {[llength $cordic_ip] == 0} {
    if {[catch {
        create_ip -name cordic -vendor xilinx.com -library ip \
            -version 6.0 -module_name $cordic_name -dir $ip_dir
    } create_cordic_error]} {
        puts "WARNING: CORDIC 6.0 创建失败：$create_cordic_error"
        puts "WARNING: 尝试使用 IP Catalog 中的默认 CORDIC 版本。"
        create_ip -name cordic -vendor xilinx.com -library ip \
            -module_name $cordic_name -dir $ip_dir
    }
    set cordic_ip [get_ips $cordic_name]
}

set_required_property $cordic_ip {CONFIG.Functional_Selection CONFIG.functional_selection} Translate
set_required_property $cordic_ip {CONFIG.Architectural_Configuration CONFIG.architectural_configuration} Parallel
set_required_property $cordic_ip {CONFIG.Pipelining_Mode CONFIG.pipelining_mode} Maximum
set_required_property $cordic_ip {CONFIG.Data_Format CONFIG.data_format} SignedFraction
set_required_property $cordic_ip {CONFIG.Input_Width CONFIG.input_width} 30
set_required_property $cordic_ip {CONFIG.Output_Width CONFIG.output_width} 31
set_required_property $cordic_ip {CONFIG.Round_Mode CONFIG.round_mode} Nearest_Even
set_required_property $cordic_ip {CONFIG.Flow_Control CONFIG.flow_control} Blocking
set_required_property $cordic_ip {CONFIG.Out_TREADY CONFIG.out_tready} true
set_required_property $cordic_ip {CONFIG.ARESETN CONFIG.aresetn} true
set_optional_property $cordic_ip {CONFIG.Coarse_Rotation CONFIG.coarse_rotation} true
set_optional_property $cordic_ip {CONFIG.Compensation_Scaling CONFIG.compensation_scaling} Embedded_Multiplier
set_optional_property $cordic_ip {CONFIG.ACLKEN CONFIG.aclken} false
set_optional_property $cordic_ip {CONFIG.Cartesian_Has_TLAST CONFIG.cartesian_has_tlast} false
set_optional_property $cordic_ip {CONFIG.Cartesian_Has_TUSER CONFIG.cartesian_has_tuser} false

#--------------------------------------------------------------------------
# Block Memory Generator 8.4：Single Port ROM，8192 x 16，初始化自 COE
#--------------------------------------------------------------------------
set rom_name flat_top_window_rom
set rom_ip [get_ips -quiet $rom_name]
if {[llength $rom_ip] == 0} {
    if {[catch {
        create_ip -name blk_mem_gen -vendor xilinx.com -library ip \
            -version 8.4 -module_name $rom_name -dir $ip_dir
    } create_rom_error]} {
        puts "WARNING: Block Memory Generator 8.4 创建失败：$create_rom_error"
        puts "WARNING: 尝试使用 IP Catalog 中的默认 Block Memory Generator 版本。"
        create_ip -name blk_mem_gen -vendor xilinx.com -library ip \
            -module_name $rom_name -dir $ip_dir
    }
    set rom_ip [get_ips $rom_name]
}

set_required_property $rom_ip {CONFIG.Interface_Type CONFIG.interface_type} Native
set_required_property $rom_ip {CONFIG.Memory_Type CONFIG.memory_type} Single_Port_ROM
set_required_property $rom_ip {CONFIG.PRIM_type_to_Implement CONFIG.PRIM_TYPE_TO_IMPLEMENT} BRAM
set_required_property $rom_ip {CONFIG.Enable_A CONFIG.enable_a} Use_ENA_Pin
set_required_property $rom_ip {CONFIG.Write_Width_A CONFIG.write_width_a} 16
set_required_property $rom_ip {CONFIG.Write_Depth_A CONFIG.write_depth_a} 8192
set_required_property $rom_ip {CONFIG.Read_Width_A CONFIG.read_width_a} 16
# Vivado 2025.2 在单独修改上述任一属性时会先校验另一个属性：Coe_File
# 在 Load_Init_File=false 时被禁用，而 Load_Init_File=true 又要求 COE 已存在。
# 因此这两个相关属性必须通过一次 -dict 原子更新。
set rom_properties [list_property $rom_ip]
foreach rom_prop {CONFIG.Coe_File CONFIG.Load_Init_File} {
    if {[lsearch -exact $rom_properties $rom_prop] < 0 &&
        [lsearch -exact $rom_properties [string tolower $rom_prop]] < 0} {
        error "Block Memory Generator 不支持必要属性 $rom_prop。"
    }
}
set_property -dict [list CONFIG.Coe_File $coe_file CONFIG.Load_Init_File true] $rom_ip
set_optional_property $rom_ip {CONFIG.Register_PortA_Output_of_Memory_Primitives CONFIG.register_porta_output_of_memory_primitives} true
set_optional_property $rom_ip {CONFIG.Register_PortA_Output_of_Memory_Core CONFIG.register_porta_output_of_memory_core} false
set_optional_property $rom_ip {CONFIG.Use_Byte_Write_Enable CONFIG.use_byte_write_enable} false
set_optional_property $rom_ip {CONFIG.Port_A_Clock CONFIG.port_a_clock} 100
set_optional_property $rom_ip {CONFIG.Port_A_Enable_Rate CONFIG.port_a_enable_rate} 100

#--------------------------------------------------------------------------
# 生成 IP 输出、刷新编译顺序并设置 Step 2 联调顶层
#--------------------------------------------------------------------------
generate_target all [get_ips $fft_name]
generate_target all [get_ips $cordic_name]
generate_target all [get_ips $rom_name]

update_compile_order -fileset $source_set
set_property top Capture_Calc_Subsystem $source_set
update_compile_order -fileset $source_set
# Vivado 2025.2 的 save_project 命令要求显式 project name；批处理关闭工程
# 时会自动写回当前 .xpr，因此这里不调用 save_project，避免无意义的参数错误。

puts "INFO: Step 2 IP 已生成："
puts "INFO:   [get_property NAME $fft_ip]    -> 8192 / Radix-4 Burst / Unscaled / Natural"
puts "INFO:   [get_property NAME $cordic_ip] -> Translate / SignedFraction / 30 -> 31"
puts "INFO:   [get_property NAME $rom_ip]    -> Single Port ROM / 8192 x 16 / $coe_file"
puts "INFO: Capture_Calc_Subsystem 已设为 Step 2 联调顶层。"
