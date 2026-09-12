#==============================================================================
# setup_capture_calc.tcl
#------------------------------------------------------------------------------
# 在已打开的 G_FPGA Vivado 工程中运行：
#   source scripts/setup_capture_calc.tcl
#
# 或在工程外运行：
#   vivado -mode batch -source scripts/setup_capture_calc.tcl -tclargs G_FPGA.xpr
#
# 脚本完成：
#   1) 将 sources/rtl 下的 Verilog 文件加入 sources_1；
#   2) 创建/配置 FIR Compiler：fir_compiler_lp_600k；
#   3) 创建/配置 CORDIC Square Root：cordic_sqrt_rms；
#   4) 生成 IP 输出文件，并把 Capture_Calc_Subsystem 设为本阶段临时 top。
#
# 说明：FIR/CORDIC 的 CONFIG 属性在不同 Vivado 小版本中大小写略有差异。
# set_required_property 同时尝试常见拼写；若版本不支持某个必要属性，会立即
# 报错，避免“脚本运行成功但 IP 使用默认配置”的隐蔽问题。
#==============================================================================

if {[llength [get_projects -quiet]] == 0} {
    if {[llength $argv] < 1} {
        error "请先打开 G_FPGA.xpr，或以 -tclargs G_FPGA.xpr 运行本脚本。"
    }
    open_project [file normalize [lindex $argv 0]]
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set rtl_dir     [file normalize [file join $project_dir sources rtl]]
set coeff_dir   [file normalize [file join $project_dir sources coeffs]]
set ip_dir      [file normalize [file join $project_dir sources ip]]

file mkdir $rtl_dir
file mkdir $coeff_dir
file mkdir $ip_dir

# 将一个属性设置到第一个存在的候选名上。返回实际使用的属性名。
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

# 非关键、不同版本可能不存在的属性只给出提示。
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

#--------------------------------------------------------------------------
# RTL sources and coefficient data
#--------------------------------------------------------------------------
set rtl_files [glob -nocomplain -directory $rtl_dir *.v]
if {[llength $rtl_files] > 0} {
    add_files -norecurse $rtl_files
}

set coeff_file [file join $coeff_dir fir_lp_600k_95t.coe]
if {[file exists $coeff_file]} {
    # .coe 同时作为工程数据文件保留，便于 GUI 中复核/替换系数。
    add_files -norecurse $coeff_file
}

#--------------------------------------------------------------------------
# FIR Compiler
#--------------------------------------------------------------------------
set fir_name fir_compiler_lp_600k
set fir_ip [get_ips -quiet $fir_name]
if {[llength $fir_ip] == 0} {
    # Vivado 2025.2 通常提供 FIR Compiler 7.2；若本机仅有其他版本，
    # fallback 让 Vivado 使用 IP Catalog 中的默认版本。
    if {[catch {
        create_ip -name fir_compiler -vendor xilinx.com -library ip \
            -version 7.2 -module_name $fir_name -dir $ip_dir
    } create_fir_error]} {
        puts "WARNING: FIR Compiler 7.2 创建失败：$create_fir_error"
        puts "WARNING: 尝试使用本机 IP Catalog 的默认 FIR Compiler 版本。"
        create_ip -name fir_compiler -vendor xilinx.com -library ip \
            -module_name $fir_name -dir $ip_dir
    }
    set fir_ip [get_ips $fir_name]
}

# 95 个实数系数；FIR Compiler 用 Quantize_Only + Q1.15 量化。
set fir_coeff_vector {0.000000000000, 0.000000000000, 0.000061035156, 0.000030517578, -0.000091552734, -0.000152587891, 0.000000000000, 0.000244140625, 0.000274658203, -0.000122070313, -0.000549316406, -0.000366210938, 0.000457763672, 0.000976562500, 0.000305175781, -0.001098632813, -0.001525878906, 0.000091552734, 0.002166748047, 0.001953125000, -0.001098632813, -0.003631591797, -0.001953125000, 0.002929687500, 0.005279541016, 0.001098632813, -0.005798339844, -0.006774902344, 0.001190185547, 0.009704589844, 0.007415771484, -0.005493164063, -0.014465332031, -0.006317138672, 0.012573242188, 0.019683837891, 0.002105712891, -0.023498535156, -0.024749755859, 0.007843017578, 0.041076660156, 0.029022216797, -0.030914306641, -0.077026367188, -0.031860351563, 0.117797851563, 0.290130615234, 0.366149902344, 0.290130615234, 0.117797851563, -0.031860351563, -0.077026367188, -0.030914306641, 0.029022216797, 0.041076660156, 0.007843017578, -0.024749755859, -0.023498535156, 0.002105712891, 0.019683837891, 0.012573242188, -0.006317138672, -0.014465332031, -0.005493164063, 0.007415771484, 0.009704589844, 0.001190185547, -0.006774902344, -0.005798339844, 0.001098632813, 0.005279541016, 0.002929687500, -0.001953125000, -0.003631591797, -0.001098632813, 0.001953125000, 0.002166748047, 0.000091552734, -0.001525878906, -0.001098632813, 0.000305175781, 0.000976562500, 0.000457763672, -0.000366210938, -0.000549316406, -0.000122070313, 0.000274658203, 0.000244140625, 0.000000000000, -0.000152587891, -0.000091552734, 0.000030517578, 0.000061035156, 0.000000000000, 0.000000000000}

# 基本数据格式与滤波规格。
set_required_property $fir_ip {CONFIG.Filter_Type CONFIG.filter_type} Single_Rate
set_required_property $fir_ip {CONFIG.Coefficient_Source CONFIG.CoefficientSource CONFIG.coefficientsource} Vector
set_required_property $fir_ip {CONFIG.CoefficientVector CONFIG.coefficientvector} $fir_coeff_vector
set_required_property $fir_ip {CONFIG.Coefficient_Sets CONFIG.coefficient_sets} 1
set_required_property $fir_ip {CONFIG.Coefficient_Reload CONFIG.coefficient_reload} false
set_required_property $fir_ip {CONFIG.Coefficient_Sign CONFIG.coefficient_sign} Signed
set_required_property $fir_ip {CONFIG.Coefficient_Width CONFIG.coefficient_width} 16
set_optional_property $fir_ip {CONFIG.BestPrecision CONFIG.bestprecision} false
set_required_property $fir_ip {CONFIG.Coefficient_Fractional_Bits CONFIG.coefficient_fractional_bits} 15
set_required_property $fir_ip {CONFIG.Quantization CONFIG.quantization} Quantize_Only
set_required_property $fir_ip {CONFIG.Data_Sign CONFIG.data_sign} Signed
set_required_property $fir_ip {CONFIG.Data_Width CONFIG.data_width} 16
set_required_property $fir_ip {CONFIG.Data_Fractional_Bits CONFIG.data_fractional_bits} 0
set_required_property $fir_ip {CONFIG.Output_Rounding_Mode CONFIG.output_rounding_mode} Truncate_LSBs
set_required_property $fir_ip {CONFIG.Output_Width CONFIG.output_width} 16
set_required_property $fir_ip {CONFIG.Filter_Architecture CONFIG.filter_architecture} Systolic_Multiply_Accumulate

# 采样/时钟频率是 FIR 的吞吐率检查依据；本设计 FIR 工作在 adc_clk 域。
set_optional_property $fir_ip {CONFIG.Sample_Frequency CONFIG.sample_frequency} 4.096
set_optional_property $fir_ip {CONFIG.Clock_Frequency CONFIG.clock_frequency} 4.096
set_optional_property $fir_ip {CONFIG.Rate_Change_Type CONFIG.rate_change_type} Integer
set_optional_property $fir_ip {CONFIG.Interpolation_Rate CONFIG.interpolation_rate} 1
set_optional_property $fir_ip {CONFIG.Decimation_Rate CONFIG.decimation_rate} 1
set_optional_property $fir_ip {CONFIG.Number_Channels CONFIG.number_channels} 1
set_optional_property $fir_ip {CONFIG.Number_Paths CONFIG.number_paths} 1
set_required_property $fir_ip {CONFIG.M_DATA_Has_TREADY CONFIG.m_data_has_tready} true
# 某些 FIR Compiler 7.2 架构会把该参数锁定为 IP 自动选择值；不要强行
# 修改 disabled property，避免 Vivado 报“修改被忽略”的误导性 warning。
set_optional_property $fir_ip {CONFIG.DATA_Has_TLAST CONFIG.data_has_tlast} Not_Required
set_required_property $fir_ip {CONFIG.Has_ARESETn CONFIG.has_aresetn} true
set_optional_property $fir_ip {CONFIG.Reset_Data_Vector CONFIG.reset_data_vector} true

#--------------------------------------------------------------------------
# CORDIC Square Root
#--------------------------------------------------------------------------
set cordic_name cordic_sqrt_rms
set cordic_ip [get_ips -quiet $cordic_name]
if {[llength $cordic_ip] == 0} {
    if {[catch {
        create_ip -name cordic -vendor xilinx.com -library ip \
            -version 6.0 -module_name $cordic_name -dir $ip_dir
    } create_cordic_error]} {
        puts "WARNING: CORDIC 6.0 创建失败：$create_cordic_error"
        puts "WARNING: 尝试使用本机 IP Catalog 的默认 CORDIC 版本。"
        create_ip -name cordic -vendor xilinx.com -library ip \
            -module_name $cordic_name -dir $ip_dir
    }
    set cordic_ip [get_ips $cordic_name]
}

set_required_property $cordic_ip {CONFIG.Functional_Selection CONFIG.functional_selection} Square_Root
set_required_property $cordic_ip {CONFIG.Architectural_Configuration CONFIG.architectural_configuration} Parallel
set_required_property $cordic_ip {CONFIG.Pipelining_Mode CONFIG.pipelining_mode} Maximum
set_required_property $cordic_ip {CONFIG.Data_Format CONFIG.data_format} UnsignedInteger
set_required_property $cordic_ip {CONFIG.Input_Width CONFIG.input_width} 32
# Square Root 的输出宽度由输入宽度和数据格式派生；Vivado 2025.2 对
# 32-bit Unsigned Integer 输入自动得到 17 bit，不能当作可编辑属性覆盖。
set_required_property $cordic_ip {CONFIG.Round_Mode CONFIG.round_mode} Nearest_Even
set_optional_property $cordic_ip {CONFIG.Iterations CONFIG.iterations} 0
set_optional_property $cordic_ip {CONFIG.Precision CONFIG.precision} 0
set_optional_property $cordic_ip {CONFIG.Coarse_Rotation CONFIG.coarse_rotation} false
set_optional_property $cordic_ip {CONFIG.Compensation_Scaling CONFIG.compensation_scaling} No_Scale_Compensation
set_required_property $cordic_ip {CONFIG.Flow_Control CONFIG.flow_control} Blocking
set_required_property $cordic_ip {CONFIG.Out_TREADY CONFIG.out_tready} true
set_required_property $cordic_ip {CONFIG.ARESETN CONFIG.aresetn} true
set_optional_property $cordic_ip {CONFIG.ACLKEN CONFIG.aclken} false
set_optional_property $cordic_ip {CONFIG.Cartesian_Has_TLAST CONFIG.cartesian_has_tlast} false
set_optional_property $cordic_ip {CONFIG.Cartesian_Has_TUSER CONFIG.cartesian_has_tuser} false

# 生成例化模板、综合/仿真目标；IP 会自动加入当前 project。
generate_target all [get_ips $fir_name]
generate_target all [get_ips $cordic_name]

update_compile_order -fileset sources_1
set_property top Capture_Calc_Subsystem [get_filesets sources_1]
puts "INFO: Capture_Calc_Subsystem 已设为本阶段临时 top。"
puts "INFO: 若本机 Vivado 的 GUI 属性名不同，脚本会在对应属性处明确报错。"
