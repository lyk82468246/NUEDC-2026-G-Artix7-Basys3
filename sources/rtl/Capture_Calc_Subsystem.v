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
// 该模块故意不包含板级时钟管理；最终 Basys 3 顶层负责产生 adc_clk 和
// calc_clk。ADC 随路时钟域只负责并行总线采样寄存器；ADC_Input_CDC 将样本
// 送到 calc_clk，FIR、过零和时域 BRAM 写入均在全局算法时钟域完成，避免
// 把 DSP/BRAM 绑定到 Artix-7 的 BUFR 区域时钟资源。
//
// AFE 在帧完成后保持写端口冻结；HMI 完成该帧的文本/波形发送后通过
// frame_release 释放捕获器，再允许下一帧启动。这样三个消费者读取的是同一
// 个完整快照，而不会在慢速 UART 发送期间被下一帧覆盖。
//
// 它仍然是没有板级引脚约束的联调 synthesis top，后续只需在更外层加入
// MMCM、ADC 引脚、UART 引脚和实际 Basys 3 XDC 即可。
//==============================================================================
module Capture_Calc_Subsystem (
    input  wire             adc_clk,
    input  wire             calc_clk,
    input  wire             rst,
    input  wire             rst_adc,
    input  wire [11:0]      adc_data,
    input  wire             display_three_cycles,

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
    output wire             uart_tx,
    output wire             frame_valid,
    output wire             measurement_valid,
    output wire [4:0]       uart_state
);

    wire                    bram_wr_en;
    wire [12:0]             bram_wr_addr;
    wire signed [15:0]      bram_wr_data;
    wire                    frame_done_toggle;
    wire                    frame_done_pulse;
    wire                    frame_start_pulse;
    wire                    frame_release;

    wire                    adc_sample_valid_calc;
    wire [11:0]             adc_data_calc;

    // Re-create a calc_clk-domain frame pulse for the top-level ILA.  The
    // processing modules retain their own CDC synchronizers; this copy is
    // solely an observation signal and is safe to probe at 100 MHz.
    (* ASYNC_REG = "TRUE" *) reg frame_valid_sync_ff1;
    (* ASYNC_REG = "TRUE" *) reg frame_valid_sync_ff2;
    reg frame_valid_sync_d;

    always @(posedge calc_clk) begin
        if (rst) begin
            frame_valid_sync_ff1 <= 1'b0;
            frame_valid_sync_ff2 <= 1'b0;
            frame_valid_sync_d   <= 1'b0;
        end
        else begin
            frame_valid_sync_ff1 <= frame_done_toggle;
            frame_valid_sync_ff2 <= frame_valid_sync_ff1;
            frame_valid_sync_d   <= frame_valid_sync_ff2;
        end
    end

    assign frame_valid = frame_valid_sync_ff2 ^ frame_valid_sync_d;

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

    ADC_Input_CDC #(
        .ADC_WIDTH(12)
    ) u_adc_input_cdc (
        .adc_clk           (adc_clk),
        .rst_adc           (rst_adc),
        .adc_data          (adc_data),
        .calc_clk          (calc_clk),
        .rst_calc          (rst),
        .sample_valid_calc(adc_sample_valid_calc),
        .adc_data_calc     (adc_data_calc)
    );

    // All FIR/DSP and frame-write logic is clocked by calc_clk.  The sample
    // valid pulse preserves the original ADC sample cadence.
    AFE_Capture u_afe_capture (
        .adc_clk          (calc_clk),
        .rst              (rst),
        .adc_data         (adc_data_calc),
        .sample_valid     (adc_sample_valid_calc),
        .frame_release    (frame_release),
        .bram_wr_en       (bram_wr_en),
        .bram_wr_addr     (bram_wr_addr),
        .bram_wr_data     (bram_wr_data),
        .frame_done_toggle(frame_done_toggle),
        .frame_done_pulse (frame_done_pulse),
        .frame_start_pulse(frame_start_pulse),
        .capture_busy     (capture_busy)
    );

    BRAM_TimeDomain u_bram_time_domain (
        .wr_clk  (calc_clk),
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
        .display_three_cycles(display_three_cycles),
        .time_rd_en        (hmi_time_rd_en),
        .time_rd_addr      (hmi_time_rd_addr),
        .time_rd_data      (hmi_time_rd_data),
        .uart_tx           (uart_tx),
        .busy              (hmi_busy),
        .waveform_done     (waveform_done),
        .frame_release     (frame_release),
        .measurement_valid (measurement_valid),
        .state_debug       (uart_state)
    );

endmodule
