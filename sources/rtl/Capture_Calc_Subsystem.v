`timescale 1ns / 1ps

//==============================================================================
// Capture_Calc_Subsystem
//------------------------------------------------------------------------------
// 当前阶段的完整数据链路：
//   AFE_Capture
//      -> BRAM_TimeDomain（时域统计/FFT/HMI 三个独立读副本）
//      -> Time_Domain_Calc
//      -> FFT_Processor -> BRAM_FreqDomain -> Peak_Search
//      -> HMI_UART_Ctrl -> UART TX
//
// 该模块故意不包含 100 MHz -> 4.096 MHz 的 MMCM；最终 Basys 3 顶层应将：
//   adc_clk 接到 AD9226 的 4.096 MHz 采样时钟；
//   calc_clk 接到算法时钟（建议 100 MHz）；
//   rst 使用统一的高有效复位。
//
// 它仍然是没有板级引脚约束的联调 synthesis top，后续只需在更外层加入
// MMCM、ADC 引脚、UART 引脚和实际 Basys 3 XDC 即可。
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
    output wire             calc_busy,

    output wire [11:0]      max_index_out,
    output wire [31:0]      f1_hz_out,
    output wire [31:0]      amp_f1_out,
    output wire             peak_result_valid,
    output wire             fft_result_valid,
    output wire             fft_busy,
    output wire             peak_busy,
    output wire             hmi_busy,
    output wire             waveform_done,
    output wire             uart_tx
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

    wire [12:0]             fft_time_rd_addr;
    wire                    fft_time_rd_en;
    wire signed [15:0]      fft_time_rd_data;

    wire [12:0]             hmi_time_rd_addr;
    wire                    hmi_time_rd_en;
    wire signed [15:0]      hmi_time_rd_data;

    wire [11:0]             freq_wr_addr;
    wire                    freq_wr_en;
    wire [31:0]             freq_wr_data;
    wire                    freq_frame_done_toggle;
    wire                    freq_frame_done_pulse;

    wire [11:0]             freq_rd_addr;
    wire                    freq_rd_en;
    wire [31:0]             freq_rd_data;

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
        .rd_data (bram_rd_data),
        .rd2_clk (calc_clk),
        .rd2_en  (fft_time_rd_en),
        .rd2_addr(fft_time_rd_addr),
        .rd2_data(fft_time_rd_data),
        .rd3_clk (calc_clk),
        .rd3_en  (hmi_time_rd_en),
        .rd3_addr(hmi_time_rd_addr),
        .rd3_data(hmi_time_rd_data)
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

    FFT_Processor u_fft_processor (
        .calc_clk                (calc_clk),
        .rst                     (rst),
        .frame_done_toggle       (frame_done_toggle),
        .time_rd_addr            (fft_time_rd_addr),
        .time_rd_en              (fft_time_rd_en),
        .time_rd_data            (fft_time_rd_data),
        .freq_wr_addr            (freq_wr_addr),
        .freq_wr_en              (freq_wr_en),
        .freq_wr_data            (freq_wr_data),
        .freq_frame_done_toggle  (freq_frame_done_toggle),
        .freq_frame_done_pulse   (freq_frame_done_pulse),
        .frame_valid             (fft_result_valid),
        .busy                    (fft_busy)
    );

    BRAM_FreqDomain u_bram_freq_domain (
        .clk     (calc_clk),
        .wr_en   (freq_wr_en),
        .wr_addr (freq_wr_addr),
        .wr_data (freq_wr_data),
        .rd_en   (freq_rd_en),
        .rd_addr (freq_rd_addr),
        .rd_data (freq_rd_data)
    );

    Peak_Search u_peak_search (
        .calc_clk          (calc_clk),
        .rst               (rst),
        .frame_done_toggle (freq_frame_done_toggle),
        .freq_rd_addr      (freq_rd_addr),
        .freq_rd_en        (freq_rd_en),
        .freq_rd_data      (freq_rd_data),
        .max_index         (max_index_out),
        .f1_hz             (f1_hz_out),
        .amp_f1            (amp_f1_out),
        .result_valid      (peak_result_valid),
        .busy              (peak_busy)
    );

    HMI_UART_Ctrl #(
        .CLK_FREQ_HZ     (100_000_000),
        .BAUD_RATE       (115_200),
        .FRAME_LENGTH    (8192),
        .TIME_ADDR_WIDTH (13),
        .WAVE_POINTS     (400),
        .DISPLAY_CYCLES  (1)
    ) u_hmi_uart_ctrl (
        .clk               (calc_clk),
        .rst               (rst),
        .time_result_valid (result_valid),
        .vpp_in            (vpp_out),
        .vrms_in           (vrms_out),
        .peak_result_valid (peak_result_valid),
        .f1_index_in       (max_index_out),
        .f1_hz_in          (f1_hz_out),
        .amp_f1_in         (amp_f1_out),
        .time_rd_en        (hmi_time_rd_en),
        .time_rd_addr      (hmi_time_rd_addr),
        .time_rd_data      (hmi_time_rd_data),
        .uart_tx           (uart_tx),
        .busy              (hmi_busy),
        .waveform_done     (waveform_done)
    );

endmodule
