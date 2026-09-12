`timescale 1ns / 1ps

//==============================================================================
// AFE_Capture
//------------------------------------------------------------------------------
// 功能：
//   1) 将 AD9226 的 12-bit offset-binary 数据转换为有符号采样值；
//   2) 送入 Vivado FIR Compiler 低通 IP；
//   3) 用一个慢速 IIR 估计器去除残余直流分量；
//   4) 在滤波输出上检测“负 -> 正”过零点；
//   5) 从过零点开始，将连续 8192 个 16-bit 有符号采样写入时域 BRAM。
//
// 时钟域：
//   本模块所有逻辑均工作在 adc_clk 端口所接入的处理时钟域。最终板级顶层
//   将该端口接到 100 MHz 全局算法时钟，并通过 sample_valid 输入逐样本驱动
//   FIR；AD9226 的实际 4.096 MHz 随路时钟由 ADC_Input_CDC 在 BUFR 域采样。
//
// 关于 FIR IP：
//   本文件约定工程中存在一个名为 fir_compiler_lp_600k 的 FIR Compiler IP，
//   接口为 AXI4-Stream，数据宽度 16 bit，带 aresetn、输入 tready 和输出
//   tready。scripts/setup_capture_calc.tcl 会创建并配置该 IP。
//==============================================================================
module AFE_Capture #(
    parameter integer ADC_WIDTH          = 12,
    parameter integer FIR_DATA_WIDTH     = 16,
    parameter integer FRAME_LENGTH       = 8192,
    parameter integer ADDR_WIDTH         = 13,

    // AD9226 常用默认格式为 offset binary：中点码 2048 对应 0 V。
    // 若硬件已经配置为 two's complement，可将 ADC_OFFSET_BINARY 置 0。
    parameter integer ADC_OFFSET_BINARY   = 1,
    parameter integer ADC_MID_CODE        = 2048,

    // 将 12-bit ADC 的 [-2048, 2047] 放大到近似 16-bit [-32768, 32752]。
    // 该移位不会溢出 16 bit；如后级使用原始 12-bit 标度，可置为 0。
    parameter integer ADC_SCALE_SHIFT     = 4,

    // 直流估计器时间常数约为 2^DC_TRACK_SHIFT 个采样周期。
    // 默认值对应约 1 ms 时间常数、约 160 Hz 的一阶拐点，远低于 10 kHz 测量下限。
    parameter integer DC_TRACK_SHIFT      = 12,
    // 上电后给 DC 估计器一个稳定时间，避免把启动瞬态当成过零触发。
    parameter integer DC_WARMUP_SAMPLES   = 4096,
    parameter integer ZERO_THRESHOLD      = 0
)(
    input  wire                         adc_clk,
    input  wire                         rst,                 // 高有效同步复位
    input  wire [ADC_WIDTH-1:0]         adc_data,
    input  wire                         sample_valid,

    // 时域 BRAM 写端口。BRAM_TimeDomain 使用 wr_en/wr_addr/wr_data。
    output reg                          bram_wr_en,
    output reg  [ADDR_WIDTH-1:0]        bram_wr_addr,
    output reg  signed [FIR_DATA_WIDTH-1:0] bram_wr_data,

    // 每完成一帧翻转一次，用于跨到 calc_clk 域；不能直接把该信号当脉冲跨域。
    output reg                          frame_done_toggle,
    output reg                          frame_done_pulse,
    output reg                          frame_start_pulse,
    output wire                         capture_busy
);

    //-------------------------------------------------------------------------
    // ADC offset-binary -> signed conversion
    //-------------------------------------------------------------------------
    // 先扩展到 17 bit，再减去中点码，避免 12 bit 运算时发生截断。
    wire signed [ADC_WIDTH:0] adc_offset_binary_s;
    wire signed [ADC_WIDTH:0] adc_twos_complement_s;
    wire signed [ADC_WIDTH:0] adc_zeroed_s;
    wire signed [FIR_DATA_WIDTH:0] adc_zeroed_ext_s;
    wire signed [FIR_DATA_WIDTH:0] adc_scaled_s;
    wire signed [FIR_DATA_WIDTH-1:0] adc_fir_input_s;
    localparam signed [ADC_WIDTH:0] ADC_MID_CODE_S = ADC_MID_CODE;

    assign adc_offset_binary_s =
        $signed({1'b0, adc_data}) - ADC_MID_CODE_S;
    assign adc_twos_complement_s =
        $signed({{1{adc_data[ADC_WIDTH-1]}}, adc_data});
    assign adc_zeroed_s = ADC_OFFSET_BINARY ?
                          adc_offset_binary_s : adc_twos_complement_s;

    // 先显式扩展到 17 bit 再左移。Verilog 移位表达式的结果宽度由左操作数
    // 决定，若直接对 13-bit adc_zeroed_s 左移，-2048*16 会在移位时先回绕。
    assign adc_zeroed_ext_s = $signed({{(FIR_DATA_WIDTH-ADC_WIDTH){adc_zeroed_s[ADC_WIDTH]}},
                                       adc_zeroed_s});
    assign adc_scaled_s  = adc_zeroed_ext_s <<< ADC_SCALE_SHIFT;
    assign adc_fir_input_s = adc_scaled_s[FIR_DATA_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // FIR Compiler AXI4-Stream interface
    //-------------------------------------------------------------------------
    wire                              fir_s_axis_tvalid;
    wire                              fir_s_axis_tready;
    wire [FIR_DATA_WIDTH-1:0]         fir_s_axis_tdata;
    wire                              fir_m_axis_tvalid;
    wire                              fir_m_axis_tready;
    wire [FIR_DATA_WIDTH-1:0]         fir_m_axis_tdata;
    wire signed [FIR_DATA_WIDTH-1:0]  fir_output_s;
    wire                              fir_output_fire;

    // FIR 工作在 100 MHz，但只在 ADC_Input_CDC 提供有效样本时推进一个
    // single-rate sample。AXI4-Stream valid 间隙不会改变 FIR 的状态序列。
    assign fir_s_axis_tvalid = sample_valid && ~rst;
    assign fir_s_axis_tdata  = adc_fir_input_s;
    assign fir_m_axis_tready = 1'b1;
    assign fir_output_s      = fir_m_axis_tdata;
    assign fir_output_fire   = fir_m_axis_tvalid && fir_m_axis_tready;

    fir_compiler_lp_600k u_fir_compiler_lp_600k (
        .aclk                 (adc_clk),
        .aresetn              (~rst),
        .s_axis_data_tvalid  (fir_s_axis_tvalid),
        .s_axis_data_tready  (fir_s_axis_tready),
        .s_axis_data_tdata   (fir_s_axis_tdata),
        .m_axis_data_tvalid  (fir_m_axis_tvalid),
        .m_axis_data_tready  (fir_m_axis_tready),
        .m_axis_data_tdata   (fir_m_axis_tdata)
    );

    //-------------------------------------------------------------------------
    // Residual DC removal
    //-------------------------------------------------------------------------
    // FIR 输出仍可能含有输入信号的直流偏置。使用慢速一阶 IIR：
    //   dc[n+1] = dc[n] + (x[n] - dc[n]) / 2^DC_TRACK_SHIFT
    //   ac[n]   = x[n] - dc[n]
    // 用 18 bit 保存估计值和误差，避免中间减法溢出。
    reg signed [FIR_DATA_WIDTH+1:0] dc_estimate_s;
    wire signed [FIR_DATA_WIDTH+1:0] fir_output_ext_s;
    wire signed [FIR_DATA_WIDTH+1:0] dc_error_s;
    wire signed [FIR_DATA_WIDTH+1:0] dc_correction_s;
    wire signed [FIR_DATA_WIDTH+1:0] dc_estimate_next_s;
    wire signed [FIR_DATA_WIDTH+1:0] ac_output_ext_s;
    wire signed [FIR_DATA_WIDTH-1:0] ac_output_s;

    assign fir_output_ext_s   = $signed({{2{fir_output_s[FIR_DATA_WIDTH-1]}},
                                         fir_output_s});
    assign dc_error_s         = fir_output_ext_s - dc_estimate_s;
    assign dc_correction_s    = dc_error_s >>> DC_TRACK_SHIFT;
    assign dc_estimate_next_s = dc_estimate_s + dc_correction_s;
    assign ac_output_ext_s    = fir_output_ext_s - dc_estimate_s;

    // 将直流去除后的结果限制到 16 bit，避免启动瞬态或大偏置造成回绕。
    localparam signed [FIR_DATA_WIDTH+1:0] AC_MAX_EXT =
        (1 <<< (FIR_DATA_WIDTH-1)) - 1;
    localparam signed [FIR_DATA_WIDTH+1:0] AC_MIN_EXT =
        -(1 <<< (FIR_DATA_WIDTH-1));

    function [FIR_DATA_WIDTH-1:0] saturate_ac_sample;
        input signed [FIR_DATA_WIDTH+1:0] value;
        begin
            if (value > AC_MAX_EXT)
                saturate_ac_sample = {1'b0, {(FIR_DATA_WIDTH-1){1'b1}}};
            else if (value < AC_MIN_EXT)
                saturate_ac_sample = {1'b1, {(FIR_DATA_WIDTH-1){1'b0}}};
            else
                saturate_ac_sample = value[FIR_DATA_WIDTH-1:0];
        end
    endfunction

    assign ac_output_s = saturate_ac_sample(ac_output_ext_s);

    //-------------------------------------------------------------------------
    // Zero-crossing trigger and frame capture FSM
    //-------------------------------------------------------------------------
    localparam [1:0] ST_WAIT_CROSS = 2'd0;
    localparam [1:0] ST_CAPTURE    = 2'd1;
    localparam [1:0] ST_REARM      = 2'd2;
    localparam [ADDR_WIDTH-1:0] LAST_FRAME_ADDR = FRAME_LENGTH - 1;
    localparam [ADDR_WIDTH-1:0] FIRST_AFTER_TRIGGER = {{(ADDR_WIDTH-1){1'b0}},1'b1};

    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] write_addr_next;
    reg signed [FIR_DATA_WIDTH-1:0] previous_sample_s;
    reg                             have_previous_sample;
    reg [15:0]                      dc_warmup_count;
    reg                             dc_ready;
    // BRAM 写端口是寄存器输出：最后一个采样请求在当前时钟沿被送到
    // BRAM 端口，真正写入发生在下一个 adc_clk 沿。因此帧完成 toggle
    // 延后一拍，确保 calc_clk 域永远不会在最后一个写入提交前开始读取。
    reg                             frame_done_pending;
    wire signed [FIR_DATA_WIDTH-1:0] zero_threshold_s;

    assign zero_threshold_s = ZERO_THRESHOLD;
    assign capture_busy = (state == ST_CAPTURE);

    always @(posedge adc_clk) begin
        if (rst) begin
            state              <= ST_WAIT_CROSS;
            write_addr_next    <= {ADDR_WIDTH{1'b0}};
            previous_sample_s  <= {FIR_DATA_WIDTH{1'b0}};
            have_previous_sample <= 1'b0;
            dc_estimate_s      <= {(FIR_DATA_WIDTH+2){1'b0}};
            dc_warmup_count    <= 16'd0;
            dc_ready           <= (DC_WARMUP_SAMPLES == 0);
            frame_done_pending <= 1'b0;

            bram_wr_en         <= 1'b0;
            bram_wr_addr       <= {ADDR_WIDTH{1'b0}};
            bram_wr_data       <= {FIR_DATA_WIDTH{1'b0}};
            frame_done_toggle  <= 1'b0;
            frame_done_pulse   <= 1'b0;
            frame_start_pulse  <= 1'b0;
        end
        else begin
            // 写使能和事件信号均为单周期脉冲，默认拉低。
            bram_wr_en        <= 1'b0;
            frame_done_pulse  <= 1'b0;
            frame_start_pulse <= 1'b0;

            // 上一拍已经请求了最后一个 BRAM 写入；本拍 BRAM 同时提交
            // 该写入，随后才通知 calc_clk 域开始计算。
            if (frame_done_pending) begin
                frame_done_toggle <= ~frame_done_toggle;
                frame_done_pulse  <= 1'b1;
                frame_done_pending <= 1'b0;
            end

            if (fir_output_fire) begin
                // 直流估计在每个有效 FIR 样本到来时更新。
                dc_estimate_s <= dc_estimate_next_s;

                // 计数的是 FIR 有效样本而不是原始 ADC 时钟，保证 FIR 有停顿时
                // 不会提前结束 warm-up。
                if (!dc_ready) begin
                    if (dc_warmup_count == DC_WARMUP_SAMPLES-1) begin
                        dc_ready <= 1'b1;
                    end
                    else begin
                        dc_warmup_count <= dc_warmup_count + 1'b1;
                    end
                end

                // 上一个有效样本只用于过零判定，不能用“上一个时钟”代替，
                // 因为 FIR 输出可能存在 valid 间隙。
                if (have_previous_sample) begin
                    case (state)
                        ST_WAIT_CROSS: begin
                            // 负(含零) -> 正，当前样本作为 frame[0] 写入。
                            if (dc_ready &&
                                (previous_sample_s <= zero_threshold_s) &&
                                (ac_output_s       >  zero_threshold_s)) begin
                                bram_wr_en       <= 1'b1;
                                bram_wr_addr     <= {ADDR_WIDTH{1'b0}};
                                bram_wr_data     <= ac_output_s;
                                write_addr_next  <= FIRST_AFTER_TRIGGER;
                                frame_start_pulse <= 1'b1;
                                state            <= ST_CAPTURE;
                            end
                        end

                        ST_CAPTURE: begin
                            // frame[0] 已在触发分支中写入；此处从地址 1 开始。
                            bram_wr_en   <= 1'b1;
                            bram_wr_addr <= write_addr_next;
                            bram_wr_data <= ac_output_s;

                            if (write_addr_next == LAST_FRAME_ADDR) begin
                                // 最后一个采样请求已经送出。由于 BRAM 写端口
                                // 为寄存器输出，完成通知在下一拍产生。
                                frame_done_pending <= 1'b1;
                                write_addr_next   <= {ADDR_WIDTH{1'b0}};
                                state             <= ST_REARM;
                            end
                            else begin
                                write_addr_next <= write_addr_next + 1'b1;
                            end
                        end

                        ST_REARM: begin
                            // 防止帧末尾仍处于正半周时立即重复触发。
                            // 先等信号回到零点以下，再重新等待负 -> 正。
                            if (ac_output_s <= zero_threshold_s)
                                state <= ST_WAIT_CROSS;
                        end

                        default: begin
                            state <= ST_WAIT_CROSS;
                        end
                    endcase
                end

                previous_sample_s   <= ac_output_s;
                have_previous_sample <= 1'b1;
            end
        end
    end

endmodule
