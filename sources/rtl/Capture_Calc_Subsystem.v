`timescale 1ns / 1ps

//==============================================================================
// Capture_Calc_Subsystem
//------------------------------------------------------------------------------
// 本阶段联调用封装：
//   AFE_Capture -> BRAM_TimeDomain -> Time_Domain_Calc
//
// 该模块故意不包含 100 MHz -> 4.096 MHz 的 MMCM；最终 Basys 3 顶层应将：
//   adc_clk 接到 AD9226 的 4.096 MHz 采样时钟；
//   calc_clk 接到算法时钟（建议 100 MHz）；
//   rst 使用统一的高有效复位。
//
// 它可以作为本阶段 Vivado 的临时 synthesis top，后续做 UART/FFT 顶层时，
// 只需复用其中的三段例化和端口连接。
//==============================================================================
module Capture_Calc_Subsystem (
    input  wire             adc_clk,
    input  wire             calc_clk,
    input  wire             rst,
    input  wire [11:0]      adc_data,

    output wire [16:0]      vpp_out,
    output wire [15:0]      vrms_out,
    output wire [31:0]      mean_square_out,
    output wire             result_valid,
    output wire             capture_busy,
    output wire             calc_busy
);

    wire                    bram_wr_en;
    wire [12:0]             bram_wr_addr;
    wire signed [15:0]      bram_wr_data;
    wire                    frame_done_toggle;
    wire                    frame_done_pulse;
    wire                    frame_start_pulse;

    wire [12:0]             bram_rd_addr;
    wire                    bram_rd_en;
    wire signed [15:0]      bram_rd_data;

    AFE_Capture u_afe_capture (
        .adc_clk          (adc_clk),
        .rst              (rst),
        .adc_data         (adc_data),
        .bram_wr_en       (bram_wr_en),
        .bram_wr_addr     (bram_wr_addr),
        .bram_wr_data     (bram_wr_data),
        .frame_done_toggle(frame_done_toggle),
        .frame_done_pulse (frame_done_pulse),
        .frame_start_pulse(frame_start_pulse),
        .capture_busy     (capture_busy)
    );

    BRAM_TimeDomain u_bram_time_domain (
        .wr_clk  (adc_clk),
        .wr_en   (bram_wr_en),
        .wr_addr (bram_wr_addr),
        .wr_data (bram_wr_data),
        .rd_clk  (calc_clk),
        .rd_en   (bram_rd_en),
        .rd_addr (bram_rd_addr),
        .rd_data (bram_rd_data)
    );

    Time_Domain_Calc u_time_domain_calc (
        .calc_clk        (calc_clk),
        .rst             (rst),
        .frame_done_toggle(frame_done_toggle),
        .bram_rd_addr    (bram_rd_addr),
        .bram_rd_en      (bram_rd_en),
        .bram_rd_data    (bram_rd_data),
        .vpp_out         (vpp_out),
        .vrms_out        (vrms_out),
        .mean_square_out (mean_square_out),
        .result_valid    (result_valid),
        .busy            (calc_busy)
    );

endmodule
