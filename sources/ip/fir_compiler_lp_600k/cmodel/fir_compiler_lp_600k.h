
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
// coefficients: 0.000000000000,0.000000000000,0.000061035156,0.000030517578,-0.000091552734,-0.000152587891,0.000000000000,0.000244140625,0.000274658203,-0.000122070313,-0.000549316406,-0.000366210938,0.000457763672,0.000976562500,0.000305175781,-0.001098632813,-0.001525878906,0.000091552734,0.002166748047,0.001953125000,-0.001098632813,-0.003631591797,-0.001953125000,0.002929687500,0.005279541016,0.001098632813,-0.005798339844,-0.006774902344,0.001190185547,0.009704589844,0.007415771484,-0.005493164063,-0.014465332031,-0.006317138672,0.012573242188,0.019683837891,0.002105712891,-0.023498535156,-0.024749755859,0.007843017578,0.041076660156,0.029022216797,-0.030914306641,-0.077026367188,-0.031860351563,0.117797851563,0.290130615234,0.366149902344,0.290130615234,0.117797851563,-0.031860351563,-0.077026367188,-0.030914306641,0.029022216797,0.041076660156,0.007843017578,-0.024749755859,-0.023498535156,0.002105712891,0.019683837891,0.012573242188,-0.006317138672,-0.014465332031,-0.005493164063,0.007415771484,0.009704589844,0.001190185547,-0.006774902344,-0.005798339844,0.001098632813,0.005279541016,0.002929687500,-0.001953125000,-0.003631591797,-0.001098632813,0.001953125000,0.002166748047,0.000091552734,-0.001525878906,-0.001098632813,0.000305175781,0.000976562500,0.000457763672,-0.000366210938,-0.000549316406,-0.000122070313,0.000274658203,0.000244140625,0.000000000000,-0.000152587891,-0.000091552734,0.000030517578,0.000061035156,0.000000000000,0.000000000000
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
// coeff_fract_width: 15
// chan_seq: 0
// num_channels: 1
// num_paths: 1
// data_width: 16
// data_fract_width: 0
// output_rounding_mode: 1
// output_width: 16
// accum_width: 32
// output_fract_width: 0
// config_method: 0

const double fir_compiler_lp_600k_coefficients[95] = {0.000000000000,0.000000000000,0.000061035156,0.000030517578,-0.000091552734,-0.000152587891,0.000000000000,0.000244140625,0.000274658203,-0.000122070313,-0.000549316406,-0.000366210938,0.000457763672,0.000976562500,0.000305175781,-0.001098632813,-0.001525878906,0.000091552734,0.002166748047,0.001953125000,-0.001098632813,-0.003631591797,-0.001953125000,0.002929687500,0.005279541016,0.001098632813,-0.005798339844,-0.006774902344,0.001190185547,0.009704589844,0.007415771484,-0.005493164063,-0.014465332031,-0.006317138672,0.012573242188,0.019683837891,0.002105712891,-0.023498535156,-0.024749755859,0.007843017578,0.041076660156,0.029022216797,-0.030914306641,-0.077026367188,-0.031860351563,0.117797851563,0.290130615234,0.366149902344,0.290130615234,0.117797851563,-0.031860351563,-0.077026367188,-0.030914306641,0.029022216797,0.041076660156,0.007843017578,-0.024749755859,-0.023498535156,0.002105712891,0.019683837891,0.012573242188,-0.006317138672,-0.014465332031,-0.005493164063,0.007415771484,0.009704589844,0.001190185547,-0.006774902344,-0.005798339844,0.001098632813,0.005279541016,0.002929687500,-0.001953125000,-0.003631591797,-0.001098632813,0.001953125000,0.002166748047,0.000091552734,-0.001525878906,-0.001098632813,0.000305175781,0.000976562500,0.000457763672,-0.000366210938,-0.000549316406,-0.000122070313,0.000274658203,0.000244140625,0.000000000000,-0.000152587891,-0.000091552734,0.000030517578,0.000061035156,0.000000000000,0.000000000000};

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
  config.coeff_fract_width   = 15;
  config.chan_seq            = XIP_FIR_BASIC_CHAN_SEQ;
  config.num_channels        = 1;
  config.init_pattern        = fir_compiler_lp_600k_chanpats[0];
  config.num_paths           = 1;
  config.data_width          = 16;
  config.data_fract_width    = 0;
  config.output_rounding_mode= XIP_FIR_TRUNCATE_LSBS;
  config.output_width        = 16;
  config.accum_width         = 32;
  config.output_fract_width  = 0;
  config.config_method       = XIP_FIR_CONFIG_SINGLE;
  return config;
}

const xip_fir_v7_2_config fir_compiler_lp_600k_config = gen_fir_compiler_lp_600k_config();

