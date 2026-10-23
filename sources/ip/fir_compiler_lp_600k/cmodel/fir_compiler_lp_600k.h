
//------------------------------------------------------------------------------
// (c) Copyright 2023 Advanced Micro Devices. All rights reserved.
//
// This file contains confidential and proprietary information
// of AMD, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// AMD, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) AMD shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or AMD had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// AMD products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of AMD products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//------------------------------------------------------------------------------ 
//
// C Model configuration for the "fir_compiler_lp_600k" instance.
//
//------------------------------------------------------------------------------
//
// coefficients: 0.000061035156,0.000091552734,0.000030517578,-0.000152587891,-0.000183105469,0.000000000000,0.000213623047,0.000152587891,-0.000122070312,-0.000244140625,0.000030517578,0.000305175781,0.000091552734,-0.000366210938,-0.000335693359,0.000335693359,0.000701904297,0.000091552734,-0.000885009766,-0.000823974609,0.000427246094,0.001220703125,0.000457763672,-0.000823974609,-0.000885009766,0.000152587891,0.000427246094,-0.000427246094,-0.000305175781,0.001678466797,0.002410888672,-0.001373291016,-0.006225585938,-0.003906250000,0.006774902344,0.013305664062,0.002563476562,-0.018249511719,-0.022186279297,0.005615234375,0.039520263672,0.031677246094,-0.029357910156,-0.083953857422,-0.044525146484,0.112457275391,0.300598144531,0.384948730469,0.300598144531,0.112457275391,-0.044525146484,-0.083953857422,-0.029357910156,0.031677246094,0.039520263672,0.005615234375,-0.022186279297,-0.018249511719,0.002563476562,0.013305664062,0.006774902344,-0.003906250000,-0.006225585938,-0.001373291016,0.002410888672,0.001678466797,-0.000305175781,-0.000427246094,0.000427246094,0.000152587891,-0.000885009766,-0.000823974609,0.000457763672,0.001220703125,0.000427246094,-0.000823974609,-0.000885009766,0.000091552734,0.000701904297,0.000335693359,-0.000335693359,-0.000366210938,0.000091552734,0.000305175781,0.000030517578,-0.000244140625,-0.000122070312,0.000152587891,0.000213623047,0.000000000000,-0.000183105469,-0.000152587891,0.000030517578,0.000091552734,0.000061035156
// chanpats: 173
// name: fir_compiler_lp_600k
// data_coefficient_type: 0
// filter_type: 0
// rate_change: 0
// interp_rate: 1
// decim_rate: 1
// zero_pack_factor: 1
// coeff_padding: 0
// num_coeffs: 95
// coeff_sets: 1
// reloadable: 0
// is_halfband: 0
// quantization: 1
// coeff_width: 16
// coeff_fract_width: 16
// chan_seq: 0
// num_channels: 1
// num_paths: 1
// data_width: 16
// data_fract_width: 0
// output_rounding_mode: 1
// output_width: 16
// accum_width: 33
// output_fract_width: 0
// config_method: 0

const double fir_compiler_lp_600k_coefficients[95] = {0.000061035156,0.000091552734,0.000030517578,-0.000152587891,-0.000183105469,0.000000000000,0.000213623047,0.000152587891,-0.000122070312,-0.000244140625,0.000030517578,0.000305175781,0.000091552734,-0.000366210938,-0.000335693359,0.000335693359,0.000701904297,0.000091552734,-0.000885009766,-0.000823974609,0.000427246094,0.001220703125,0.000457763672,-0.000823974609,-0.000885009766,0.000152587891,0.000427246094,-0.000427246094,-0.000305175781,0.001678466797,0.002410888672,-0.001373291016,-0.006225585938,-0.003906250000,0.006774902344,0.013305664062,0.002563476562,-0.018249511719,-0.022186279297,0.005615234375,0.039520263672,0.031677246094,-0.029357910156,-0.083953857422,-0.044525146484,0.112457275391,0.300598144531,0.384948730469,0.300598144531,0.112457275391,-0.044525146484,-0.083953857422,-0.029357910156,0.031677246094,0.039520263672,0.005615234375,-0.022186279297,-0.018249511719,0.002563476562,0.013305664062,0.006774902344,-0.003906250000,-0.006225585938,-0.001373291016,0.002410888672,0.001678466797,-0.000305175781,-0.000427246094,0.000427246094,0.000152587891,-0.000885009766,-0.000823974609,0.000457763672,0.001220703125,0.000427246094,-0.000823974609,-0.000885009766,0.000091552734,0.000701904297,0.000335693359,-0.000335693359,-0.000366210938,0.000091552734,0.000305175781,0.000030517578,-0.000244140625,-0.000122070312,0.000152587891,0.000213623047,0.000000000000,-0.000183105469,-0.000152587891,0.000030517578,0.000091552734,0.000061035156};

const xip_fir_v7_2_pattern fir_compiler_lp_600k_chanpats[1] = {P_BASIC};

static xip_fir_v7_2_config gen_fir_compiler_lp_600k_config() {
  xip_fir_v7_2_config config;
  config.name                = "fir_compiler_lp_600k";
  config.data_coefficient_type = XIP_FIR_REAL_TYPE;
  config.filter_type         = 0;
  config.rate_change         = XIP_FIR_INTEGER_RATE;
  config.interp_rate         = 1;
  config.decim_rate          = 1;
  config.zero_pack_factor    = 1;
  config.coeff               = &fir_compiler_lp_600k_coefficients[0];
  config.coeff_padding       = 0;
  config.num_coeffs          = 95;
  config.coeff_sets          = 1;
  config.reloadable          = 0;
  config.is_halfband         = 0;
  config.quantization        = XIP_FIR_QUANTIZED_ONLY;
  config.coeff_width         = 16;
  config.coeff_fract_width   = 16;
  config.chan_seq            = XIP_FIR_BASIC_CHAN_SEQ;
  config.num_channels        = 1;
  config.init_pattern        = fir_compiler_lp_600k_chanpats[0];
  config.num_paths           = 1;
  config.data_width          = 16;
  config.data_fract_width    = 0;
  config.output_rounding_mode= XIP_FIR_TRUNCATE_LSBS;
  config.output_width        = 16;
  config.accum_width         = 33;
  config.output_fract_width  = 0;
  config.config_method       = XIP_FIR_CONFIG_SINGLE;
  return config;
}

const xip_fir_v7_2_config fir_compiler_lp_600k_config = gen_fir_compiler_lp_600k_config();

