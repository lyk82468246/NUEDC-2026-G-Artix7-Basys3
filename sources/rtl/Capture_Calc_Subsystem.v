`timescale 1ns / 1ps

//==============================================================================
// Capture_Calc_Subsystem
//------------------------------------------------------------------------------
// 当前阶段的完整数据链路：
//   AFE_Capture
//      -> BRAM_TimeDomain（时域统计/FFT/HMI 三个独立读副本）
//      -> Time_Domain_Calc
//      -> FFT_Processor -> BRAM_FreqDomain -> Peak_Search
//      -> Display_HMI -> UART TX (board default); legacy HMI_UART_Ctrl optional
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
// 板级时钟、控制和引脚由外层 G_FPGA_Top 提供。显示独占第三读副本，
// 保持态重绘也会抑制新的采集许可；显示busy时不允许覆盖源帧。
//==============================================================================
module Capture_Calc_Subsystem #(
    parameter integer CONTROLLED_CAPTURE=0,
    parameter integer WAVE_POINTS=400,
    parameter integer ENABLE_DISPLAY=0,DISPLAY_HEIGHT=160,DISPLAY_INVERT_Y=0,
    parameter integer DISPLAY_STATUS=0,
    parameter integer DISPLAY_STARTUP_CYCLES=50_000_000,DISPLAY_PAGE_REFRESH=16,
    parameter integer DISPLAY_COMMAND_GAP=10000,DISPLAY_PAGE_GAP=5_000_000,
    parameter integer DISPLAY_CURVE_ID=1,DISPLAY_CHANNEL=0,
    parameter integer MIN_SIGNAL_RMS=64
)(
    input  wire             adc_clk,
    input  wire             calc_clk,
    input  wire             rst,
    input  wire             rst_adc,
    input  wire [11:0]      adc_data,
    input  wire             display_three_cycles,
    input  wire             capture_enable,
    input  wire             controller_release,
    input  wire [1:0]       mode_active,
    input wire display_page_fft,display_cycles_request,single_mode,
    input wire [31:0] display_frame_id,display_calibration_epoch,
    input wire [31:0] display_vpp_gain,display_rms_gain,display_fft_gain,
    input wire display_calibration_valid,
    input wire [3:0] display_error_code,

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
    output wire [4:0]       uart_state,
    output wire             capture_start,
    output wire             packet_finished,
    output wire             acquisition_fault,
    output wire             signal_valid_out,
    output wire [1:0]       component_count_out,
    output wire [35:0]      component_bins_out,
    output wire [95:0]      component_magnitudes_out,
    output wire [31:0]      noise_mean_out,
    // Read-only diagnostic taps. Raw candidates remain visible when invalid.
    output wire [11:0]      diagnostic_adc,
    output wire [35:0]      diagnostic_bins
);

    wire                    bram_wr_en;
    wire [12:0]             bram_wr_addr;
    wire signed [15:0]      bram_wr_data;
    wire                    frame_done_toggle;
    wire                    frame_done_pulse;
    wire                    frame_start_pulse;
    wire                    frame_release;
    wire                    hmi_frame_release;
    wire                    tx_idle;
    wire                    adc_sample_valid_calc;
    wire [11:0]             adc_data_calc;
    assign frame_release = CONTROLLED_CAPTURE ? controller_release : hmi_frame_release;
    assign capture_start = frame_start_pulse;
    assign packet_finished = hmi_frame_release && !hmi_busy && tx_idle;
    // Diagnostic rail hit during capture, not a calibrated overload detector.
    assign acquisition_fault = capture_busy && adc_sample_valid_calc &&
                              ((adc_data_calc==12'd0) || (adc_data_calc==12'hfff));

    assign diagnostic_adc=adc_data_calc;

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
    AFE_Capture #(.CONTROLLED_CAPTURE(CONTROLLED_CAPTURE)) u_afe_capture (
        .adc_clk          (calc_clk),
        .rst              (rst),
        .adc_data         (adc_data_calc),
        .sample_valid     (adc_sample_valid_calc),
        .frame_release    (frame_release),
        // The retained frame may be replayed while the run controller is idle.
        // A pending arm waits for the replay UART drain before writing BRAM.
        .capture_enable   (capture_enable && (!ENABLE_DISPLAY || !hmi_busy)),
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

    wire [11:0] analyzed_index;
    wire [31:0] analyzed_frequency,analyzed_magnitude;
    wire spectral_valid;
    wire [1:0] analyzed_count;
    wire [35:0] analyzed_bins;
    assign diagnostic_bins=analyzed_bins;
    wire [95:0] analyzed_magnitudes;
    // Time statistics complete before the FFT's serial input loading ends in
    // this architecture. HMI separately snapshots BOTH qualifiers atomically.
    wire qualified=!CONTROLLED_CAPTURE || (spectral_valid && vrms_out>=MIN_SIGNAL_RMS);
    assign max_index_out=qualified?analyzed_index:12'd0;
    assign f1_hz_out=qualified?analyzed_frequency:32'd0;
    assign amp_f1_out=qualified?analyzed_magnitude:32'd0;
    assign component_count_out=qualified?analyzed_count:2'd0;
    assign component_bins_out=qualified?analyzed_bins:36'd0;
    assign component_magnitudes_out=qualified?analyzed_magnitudes:96'd0;

    generate if(CONTROLLED_CAPTURE) begin:g_components
        Component_Analyzer u_components(
            .clk(calc_clk),.rst(rst),.frame_done_toggle(freq_frame_done_toggle),.mode(mode_active),
            .rd_addr(freq_rd_addr),.rd_en(freq_rd_en),.rd_data(freq_rd_data),
            .component_count(analyzed_count),.component_bins(analyzed_bins),
            .component_magnitudes(analyzed_magnitudes),.fundamental_bin(analyzed_index),
            .fundamental_hz(analyzed_frequency),.fundamental_magnitude(analyzed_magnitude),
            .harmonics_consistent(spectral_valid),.noise_mean_raw(noise_mean_out),
            .result_valid(peak_result_valid),.busy(peak_busy));
    end else begin:g_legacy_peak
    assign spectral_valid=1'b1;
    assign analyzed_count=0;assign analyzed_bins=0;assign analyzed_magnitudes=0;assign noise_mean_out=0;
    Peak_Search u_peak_search (
        .calc_clk          (calc_clk),
        .rst               (rst),
        .frame_done_toggle (freq_frame_done_toggle),
        .search_start_in   ((mode_active==3)?12'd10:12'd20),
        .search_end_in     ((mode_active==0)?12'd400:((mode_active==3)?12'd4000:12'd1000)),
        .freq_rd_addr      (freq_rd_addr),
        .freq_rd_en        (freq_rd_en),
        .freq_rd_data      (freq_rd_data),
        .max_index         (analyzed_index),
        .f1_hz             (analyzed_frequency),
        .amp_f1            (analyzed_magnitude),
        .result_valid      (peak_result_valid),
        .busy              (peak_busy)
    );
    end endgenerate

    generate if(ENABLE_DISPLAY) begin:g_display
        Display_HMI #(.W(WAVE_POINTS),.H(DISPLAY_HEIGHT),.INVERT_Y(DISPLAY_INVERT_Y),
            .ENABLE_STATUS(DISPLAY_STATUS),.STARTUP_CYCLES(DISPLAY_STARTUP_CYCLES),
            .PAGE_REFRESH_FRAMES(DISPLAY_PAGE_REFRESH),.COMMAND_GAP_CYCLES(DISPLAY_COMMAND_GAP),
            .PAGE_GAP_CYCLES(DISPLAY_PAGE_GAP),.CURVE_ID(DISPLAY_CURVE_ID),.CHANNEL_ID(DISPLAY_CHANNEL)) u_display(
            .clk(calc_clk),.rst(rst),.capture_start(frame_start_pulse),
            .allow_redraw(!capture_enable && !capture_busy && CONTROLLED_CAPTURE),
            .time_result_valid(result_valid),.peak_result_valid(peak_result_valid),
            .vpp_raw(vpp_out),.rms_raw(vrms_out),.signal_valid(qualified),
            .component_count(CONTROLLED_CAPTURE?analyzed_count:2'd1),
            .component_bins(CONTROLLED_CAPTURE?analyzed_bins:{24'd0,analyzed_index}),
            .component_magnitudes(CONTROLLED_CAPTURE?analyzed_magnitudes:{64'd0,analyzed_magnitude}),
            .frame_id(display_frame_id),.calibration_epoch(display_calibration_epoch),
            .vpp_gain(display_vpp_gain),.rms_gain(display_rms_gain),.fft_gain(display_fft_gain),
            .calibration_valid(display_calibration_valid),.page_fft_request(display_page_fft),
            .three_cycles_request(display_cycles_request),.single_mode(single_mode),
            .mode(mode_active),.error_code(display_error_code),
            .time_rd_en(hmi_time_rd_en),.time_rd_addr(hmi_time_rd_addr),.time_rd_data(hmi_time_rd_data),
            .uart_tx(uart_tx),.tx_idle(tx_idle),.busy(hmi_busy),.frame_release(hmi_frame_release),
            .measurement_valid(measurement_valid),.signal_valid_out(signal_valid_out),
            .waveform_done(waveform_done),.state_debug(uart_state));
    end else begin:g_legacy_hmi
    HMI_UART_Ctrl #(
        .CLK_FREQ_HZ     (100_000_000),
        .BAUD_RATE       (115_200),
        .FRAME_LENGTH    (8192),
        .TIME_ADDR_WIDTH (13),
        .WAVE_POINTS     (WAVE_POINTS),
        .DISPLAY_CYCLES  (1),
        .VALIDATE_SIGNAL (CONTROLLED_CAPTURE),
        .MIN_SIGNAL_RMS  (MIN_SIGNAL_RMS)
    ) u_hmi_uart_ctrl (
        .clk               (calc_clk),
        .rst               (rst),
        .time_result_valid (result_valid),
        .vpp_in            (vpp_out),
        .vrms_in           (vrms_out),
        .peak_result_valid (peak_result_valid),
        .f1_index_in       (analyzed_index),
        .f1_hz_in          (analyzed_frequency),
        .amp_f1_in         (analyzed_magnitude),
        .signal_valid_in   (spectral_valid),
        .signal_valid_out  (signal_valid_out),
        .display_three_cycles(display_three_cycles),
        .time_rd_en        (hmi_time_rd_en),
        .time_rd_addr      (hmi_time_rd_addr),
        .time_rd_data      (hmi_time_rd_data),
        .uart_tx           (uart_tx),
        .tx_idle           (tx_idle),
        .busy              (hmi_busy),
        .waveform_done     (waveform_done),
        .frame_release     (hmi_frame_release),
        .measurement_valid (measurement_valid),
        .state_debug       (uart_state)
    );
    end endgenerate

endmodule
