`timescale 1ns / 1ps

//==============================================================================
// HMI_UART_Ctrl
//------------------------------------------------------------------------------
// 7 寸 UART 串口屏控制器（100 MHz 时钟域）。
//
// 每当时域计算和谱峰搜索都产生新结果后，本模块：
//   1) 用四个 BIN2BCD 实例并行转换 Vpp、Vrms、f1、amp_f1；
//   2) 逐字节发送四条文本控件更新命令；
//   3) 从 BRAM_TimeDomain 的 HMI 读口抽取 400 个点；
//   4) 把采样值缩放成 0..255，并发送淘晶驰 add 曲线命令。
//
// UART 发送器只接受一个字节的 start 脉冲。消息状态机仅在 UART 空闲时
// 发出下一字节，因此任何一个字节都不会被覆盖。波形部分使用单独的
// 分时状态机，400 点发送期间不会阻塞当前结果的计算；为保证时域
// BRAM 快照与结果属于同一帧，AFE 在最后一个曲线结束符发送完成前保持
// HOLD，发送完成后由 frame_release 电平握手重新武装下一帧采集。
//==============================================================================
module HMI_UART_Ctrl #(
    parameter integer CLK_FREQ_HZ    = 100_000_000,
    parameter integer BAUD_RATE      = 115_200,
    parameter integer FRAME_LENGTH   = 8192,
    parameter integer TIME_ADDR_WIDTH= 13,
    parameter integer WAVE_POINTS    = 400,
    parameter integer DISPLAY_CYCLES = 1
)(
    input  wire                                  clk,
    input  wire                                  rst,

    input  wire                                  time_result_valid,
    input  wire [16:0]                            vpp_in,
    input  wire [15:0]                            vrms_in,

    input  wire                                  peak_result_valid,
    input  wire [11:0]                            f1_index_in,
    input  wire [31:0]                            f1_hz_in,
    input  wire [31:0]                            amp_f1_in,

    // 0: display one period, 1: display three periods.  The value is
    // latched when a new measurement packet starts.
    input  wire                                  display_three_cycles,

    // HMI 专用时域 BRAM 同步读口。
    output wire                                  time_rd_en,
    output reg  [TIME_ADDR_WIDTH-1:0]            time_rd_addr,
    input  wire signed [15:0]                    time_rd_data,

    output wire                                  uart_tx,
    output reg                                  busy,
    output reg                                  waveform_done,
    // Level handshake to AFE_Capture. It goes high after the complete HMI
    // packet has been accepted by UART_Tx and stays high until the next packet
    // starts, so a slower ADC/FIR clock cannot miss a one-cycle pulse.
    output reg                                  frame_release,
    // One-cycle event generated after the active result snapshot has been
    // loaded and one clock before BCD conversion starts. Unlike frame_valid,
    // this event means that the four displayed result registers already belong
    // to the same completed measurement packet. It is the top-level ILA
    // trigger.
    output reg                                  measurement_valid,
    // HMI message FSM state for the top-level ILA.
    output wire [4:0]                            state_debug
);

    //-------------------------------------------------------------------------
    // Result latches and four parallel binary-to-BCD converters
    //-------------------------------------------------------------------------
    reg [16:0] vpp_latched;
    reg [15:0] vrms_latched;
    reg [11:0] f1_index_latched;
    reg [31:0] f1_hz_latched;
    reg [31:0] amp_f1_latched;
    reg        display_three_cycles_latched;
    reg        have_time_result;
    reg        have_peak_result;

    // Active packet snapshot. The *_latched registers above are a one-entry
    // pending mailbox; these registers remain unchanged from BCD conversion
    // through the final waveform byte, so a result arriving during a long UART
    // transfer cannot mix values from two measurements.
    reg [16:0] vpp_active;
    reg [15:0] vrms_active;
    reg [11:0] f1_index_active;
    reg [31:0] f1_hz_active;
    reg [31:0] amp_f1_active;

    wire [39:0] vpp_bcd;
    wire [39:0] vrms_bcd;
    wire [39:0] f1_bcd;
    wire [39:0] amp_f1_bcd;
    wire        vpp_bcd_done;
    wire        vrms_bcd_done;
    wire        f1_bcd_done;
    wire        amp_f1_bcd_done;
    wire        bcd_start;

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_vpp (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in({15'd0, vpp_active}),
        .bcd_out  (vpp_bcd),
        .busy     (),
        .done     (vpp_bcd_done)
    );

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_vrms (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in({16'd0, vrms_active}),
        .bcd_out  (vrms_bcd),
        .busy     (),
        .done     (vrms_bcd_done)
    );

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_f1 (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in(f1_hz_active),
        .bcd_out  (f1_bcd),
        .busy     (),
        .done     (f1_bcd_done)
    );

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_amp_f1 (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in(amp_f1_active),
        .bcd_out  (amp_f1_bcd),
        .busy     (),
        .done     (amp_f1_bcd_done)
    );

    wire all_bcd_done;
    assign all_bcd_done = vpp_bcd_done && vrms_bcd_done &&
                          f1_bcd_done  && amp_f1_bcd_done;

    //-------------------------------------------------------------------------
    // Message helper functions
    //-------------------------------------------------------------------------
    // pos=0 is the least-significant decimal digit.
    function [3:0] bcd_digit;
        input [39:0] bcd;
        input [3:0]  pos;
        begin
            case (pos)
                4'd0: bcd_digit = bcd[3:0];
                4'd1: bcd_digit = bcd[7:4];
                4'd2: bcd_digit = bcd[11:8];
                4'd3: bcd_digit = bcd[15:12];
                4'd4: bcd_digit = bcd[19:16];
                4'd5: bcd_digit = bcd[23:20];
                4'd6: bcd_digit = bcd[27:24];
                4'd7: bcd_digit = bcd[31:28];
                4'd8: bcd_digit = bcd[35:32];
                default: bcd_digit = bcd[39:36];
            endcase
        end
    endfunction

    // Keep one zero for an all-zero measurement.
    function [3:0] first_nonzero_digit;
        input [39:0] bcd;
        begin
            if      (bcd[39:36] != 0) first_nonzero_digit = 4'd9;
            else if (bcd[35:32] != 0) first_nonzero_digit = 4'd8;
            else if (bcd[31:28] != 0) first_nonzero_digit = 4'd7;
            else if (bcd[27:24] != 0) first_nonzero_digit = 4'd6;
            else if (bcd[23:20] != 0) first_nonzero_digit = 4'd5;
            else if (bcd[19:16] != 0) first_nonzero_digit = 4'd4;
            else if (bcd[15:12] != 0) first_nonzero_digit = 4'd3;
            else if (bcd[11:8]  != 0) first_nonzero_digit = 4'd2;
            else if (bcd[7:4]   != 0) first_nonzero_digit = 4'd1;
            else                     first_nonzero_digit = 4'd0;
        end
    endfunction

    function [7:0] text_prefix_byte;
        input [1:0] id;
        input [3:0] index;
        begin
            case (index)
                4'd0: text_prefix_byte = 8'h74; // t
                4'd1: text_prefix_byte = 8'h30 + id; // 0..3
                4'd2: text_prefix_byte = 8'h2e; // .
                4'd3: text_prefix_byte = 8'h74; // t
                4'd4: text_prefix_byte = 8'h78; // x
                4'd5: text_prefix_byte = 8'h74; // t
                4'd6: text_prefix_byte = 8'h3d; // =
                default: text_prefix_byte = 8'h22; // "
            endcase
        end
    endfunction

    function [7:0] wave_prefix_byte;
        input [3:0] index;
        begin
            case (index)
                4'd0: wave_prefix_byte = 8'h61; // a
                4'd1: wave_prefix_byte = 8'h64; // d
                4'd2: wave_prefix_byte = 8'h64; // d
                4'd3: wave_prefix_byte = 8'h20; // space
                4'd4: wave_prefix_byte = 8'h31; // 1
                4'd5: wave_prefix_byte = 8'h2c; // ,
                4'd6: wave_prefix_byte = 8'h30; // 0
                default: wave_prefix_byte = 8'h2c; // ,
            endcase
        end
    endfunction

    function [7:0] wave_digit_ascii;
        input [7:0] y;
        input [1:0] length;
        input [1:0] index;
        reg [7:0] digit;
        begin
            digit = 8'd0;
            if (length == 2'd3) begin
                case (index)
                    2'd0: digit = y / 100;
                    2'd1: digit = (y / 10) % 10;
                    default: digit = y % 10;
                endcase
            end
            else if (length == 2'd2) begin
                if (index == 0)
                    digit = y / 10;
                else
                    digit = y % 10;
            end
            else begin
                digit = y;
            end
            wave_digit_ascii = 8'd48 + digit;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Waveform span and sample-coordinate helpers
    //-------------------------------------------------------------------------
    // The returned span is the final address included in the displayed region.
    // For example, one cycle with N_cycle samples uses addresses 0..N_cycle-1.
    function [31:0] calculate_wave_span;
        input [11:0] index;
        input        display_three_cycles_sel;
        reg [31:0] n_cycle;
        reg [31:0] total_samples;
        begin
            if (index == 0)
                n_cycle = FRAME_LENGTH;
            else
                n_cycle = FRAME_LENGTH / index;

            if (n_cycle == 0)
                n_cycle = 1;

            // Prefer the runtime selection.  The parameter remains a useful
            // static default for standalone reuse of this module.
            if (display_three_cycles_sel === 1'b1)
                total_samples = n_cycle * 3;
            else if (DISPLAY_CYCLES >= 3)
                total_samples = n_cycle * 3;
            else
                total_samples = n_cycle;
            if (total_samples >= FRAME_LENGTH)
                calculate_wave_span = FRAME_LENGTH - 1;
            else
                calculate_wave_span = total_samples - 1;
        end
    endfunction

    function [TIME_ADDR_WIDTH-1:0] address_from_phase;
        input [31:0] phase;
        reg [31:0] offset;
        begin
            offset = phase / (WAVE_POINTS - 1);
            if (offset >= FRAME_LENGTH)
                address_from_phase = FRAME_LENGTH - 1;
            else
                address_from_phase = offset[TIME_ADDR_WIDTH-1:0];
        end
    endfunction

    // Fallback mapping used only when Vpp=0. Normal waveforms use the dynamic
    // signed mapping below, so a small signal still occupies the display height.
    //
    // For this fallback path the screen coordinate only needs 8-bit visual
    // resolution.  Adding 32768 to a signed 16-bit two's-complement sample is
    // exactly equivalent to flipping its sign bit; taking bits [15:8] then
    // maps the full signed range to 0..255 without inferring a 16x255 DSP
    // multiplier on the 100 MHz BRAM-read path.
    function [7:0] full_scale_y;
        input signed [15:0] sample;
        begin
            full_scale_y = {~sample[15], sample[14:8]};
        end
    endfunction

    //-------------------------------------------------------------------------
    // UART and message datapath
    //-------------------------------------------------------------------------
    localparam [4:0] ST_IDLE          = 5'd0;
    localparam [4:0] ST_CONV_START    = 5'd1;
    localparam [4:0] ST_CONV_WAIT     = 5'd2;
    localparam [4:0] ST_TEXT_PREFIX   = 5'd3;
    localparam [4:0] ST_TEXT_DIGITS   = 5'd4;
    localparam [4:0] ST_TEXT_CLOSE    = 5'd5;
    localparam [4:0] ST_TEXT_TERM     = 5'd6;
    localparam [4:0] ST_WAVE_PREP      = 5'd7;
    localparam [4:0] ST_WAVE_SPAN_DIV  = 5'd8;
    localparam [4:0] ST_WAVE_READ      = 5'd9;
    localparam [4:0] ST_WAVE_PROCESS   = 5'd10;
    localparam [4:0] ST_WAVE_DIVIDE    = 5'd11;
    localparam [4:0] ST_WAVE_Y_PREP    = 5'd12;
    localparam [4:0] ST_WAVE_PREFIX    = 5'd13;
    localparam [4:0] ST_WAVE_DIGITS    = 5'd14;
    localparam [4:0] ST_WAVE_TERM      = 5'd15;
    localparam [4:0] ST_WAVE_ADDR_DIV  = 5'd16;
    // Extra register stage after the synchronous BRAM read.  This keeps the
    // BRAM output -> signed-absolute-value -> DSP48 input path comfortably
    // below the 100 MHz clock period.
    localparam [4:0] ST_WAVE_CAPTURE   = 5'd17;

    reg [4:0] state;
    reg [1:0] text_id;
    reg [3:0] text_byte_index;
    reg [3:0] text_digit_pos;
    reg [1:0] text_term_index;

    reg [31:0] wave_span;
    reg [31:0] wave_phase_acc;
    reg [8:0]  wave_point_index;
    reg [7:0]  wave_y;
    reg [1:0]  wave_y_length;
    reg [1:0]  wave_y_index;
    reg [3:0]  wave_prefix_index;
    reg [1:0]  wave_term_index;
    reg        wave_sample_negative;
    reg signed [15:0] wave_sample_reg;

    // The two waveform address calculations are intentionally iterative.
    // A variable-width divide in the ST_WAVE_PREP combinational cone made
    // Vivado infer a very deep carry chain (and failed a 100 MHz timing
    // target).  Both operations are far shorter than a UART byte time, so
    // spending a few algorithm-clock cycles here is the correct tradeoff.
    localparam integer SPAN_DIV_BITS = 14; // 8192 / f1_index
    reg [SPAN_DIV_BITS-1:0] span_div_num;
    reg [SPAN_DIV_BITS-1:0] span_div_quot;
    reg [12:0]               span_div_rem;
    reg [3:0]                span_div_count;
    reg [11:0]               span_div_den;

    wire [13:0] span_div_rem_shifted;
    wire        span_div_subtract;
    wire [12:0] span_div_rem_next;
    wire [13:0] span_div_quot_next;
    assign span_div_rem_shifted = {span_div_rem[11:0],
                                   span_div_num[SPAN_DIV_BITS-1-span_div_count]};
    assign span_div_subtract    = (span_div_rem_shifted >= {1'b0, span_div_den});
    assign span_div_rem_next    = span_div_subtract ?
                                  (span_div_rem_shifted - {1'b0, span_div_den}) :
                                  span_div_rem_shifted[12:0];
    assign span_div_quot_next   = span_div_subtract ?
                                  (span_div_quot |
                                   ({{(SPAN_DIV_BITS-1){1'b0}},1'b1} <<
                                    (SPAN_DIV_BITS-1-span_div_count))) :
                                  span_div_quot;

    wire [13:0] span_n_cycle = (span_div_quot_next == 0) ?
                               14'd1 : span_div_quot_next;
    wire [15:0] span_total_samples =
        (display_three_cycles_latched || (DISPLAY_CYCLES >= 3)) ?
        (span_n_cycle * 14'd3) : span_n_cycle;
    wire [15:0] span_limited =
        (span_total_samples >= FRAME_LENGTH) ?
        (FRAME_LENGTH - 1) : (span_total_samples - 1'b1);

    localparam integer ADDR_DIV_BITS = 23; // max phase is < 400 * 8192
    // Keep the divider generic for reduced-size simulation instances as well as
    // the production WAVE_POINTS=400 configuration.
    localparam [9:0] ADDR_DIVISOR_VALUE =
        (WAVE_POINTS > 1) ? (WAVE_POINTS - 1) : 1;
    reg [ADDR_DIV_BITS-1:0] addr_div_num;
    reg [ADDR_DIV_BITS-1:0] addr_div_quot;
    reg [9:0]                addr_div_rem;
    reg [4:0]                addr_div_count;

    wire [9:0] addr_div_rem_shifted;
    wire       addr_div_subtract;
    wire [9:0] addr_div_rem_next;
    wire [ADDR_DIV_BITS-1:0] addr_div_quot_next;
    assign addr_div_rem_shifted = {addr_div_rem[8:0],
                                   addr_div_num[ADDR_DIV_BITS-1-addr_div_count]};
    assign addr_div_subtract    = (addr_div_rem_shifted >= ADDR_DIVISOR_VALUE);
    assign addr_div_rem_next    = addr_div_subtract ?
                                  (addr_div_rem_shifted - ADDR_DIVISOR_VALUE) :
                                  addr_div_rem_shifted;
    assign addr_div_quot_next   = addr_div_subtract ?
                                  (addr_div_quot |
                                   ({{(ADDR_DIV_BITS-1){1'b0}},1'b1} <<
                                    (ADDR_DIV_BITS-1-addr_div_count))) :
                                  addr_div_quot;

    assign bcd_start = (state == ST_CONV_START);

    // Restoring divider: quotient = abs(sample) * 255 / Vpp.
    // It runs for 25 cycles, so the HMI path remains fully time-multiplexed.
    reg [24:0] div_num;
    reg [16:0] div_den;
    reg [24:0] div_quot;
    reg [17:0] div_rem;
    reg [4:0]  div_count;

    wire [16:0] wave_abs_sample;
    wire [24:0] wave_numerator;
    assign wave_abs_sample = wave_sample_reg[15] ?
                             // Sign-extend before two's-complement negate;
                             // zero-extending a negative sample would turn -1
                             // into 65537 and saturate the displayed Y value.
                             (~{1'b1, wave_sample_reg} + 17'd1) :
                             {1'b0, wave_sample_reg};
    assign wave_numerator = wave_abs_sample * 25'd255;

    wire [17:0] div_rem_shifted;
    wire        div_subtract;
    wire [17:0] div_rem_next;
    wire [24:0] div_quot_next;
    assign div_rem_shifted = {div_rem[16:0], div_num[24-div_count]};
    assign div_subtract    = (div_rem_shifted >= {1'b0, div_den});
    assign div_rem_next    = div_subtract ?
                             (div_rem_shifted - {1'b0, div_den}) :
                             div_rem_shifted;
    assign div_quot_next   = div_subtract ?
                             (div_quot | (25'b1 << (24-div_count))) :
                             div_quot;

    // Explicit combinational mux for the active measurement field.  Keeping
    // this as a plain case statement makes the selection unambiguous in both
    // Vivado synthesis and XSim when text_id=0 (Vpp); the four BCD converters
    // finish in parallel and their outputs remain stable for the whole UART
    // message.
    reg [39:0] selected_bcd;
    always @* begin
        case (text_id)
            2'd0:    selected_bcd = vpp_bcd;
            2'd1:    selected_bcd = vrms_bcd;
            2'd2:    selected_bcd = f1_bcd;
            default: selected_bcd = amp_f1_bcd;
        endcase
    end

    assign state_debug = state;

    reg  [7:0] uart_data;
    wire       uart_start;
    wire       uart_busy;

    always @* begin
        case (state)
            ST_TEXT_PREFIX:
                uart_data = text_prefix_byte(text_id, text_byte_index);
            ST_TEXT_DIGITS:
                uart_data = 8'd48 + bcd_digit(selected_bcd, text_digit_pos);
            ST_TEXT_CLOSE:
                uart_data = 8'h22; // closing quote
            ST_TEXT_TERM:
                uart_data = 8'hff;
            ST_WAVE_PREFIX:
                uart_data = wave_prefix_byte(wave_prefix_index);
            ST_WAVE_DIGITS:
                uart_data = wave_digit_ascii(wave_y, wave_y_length, wave_y_index);
            ST_WAVE_TERM:
                uart_data = 8'hff;
            default:
                uart_data = 8'h00;
        endcase
    end

    assign uart_start =
        ((state == ST_TEXT_PREFIX) || (state == ST_TEXT_DIGITS) ||
         (state == ST_TEXT_CLOSE)  || (state == ST_TEXT_TERM)   ||
         (state == ST_WAVE_PREFIX) || (state == ST_WAVE_DIGITS) ||
         (state == ST_WAVE_TERM)) && !uart_busy;

    UART_Tx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart_tx (
        .clk  (clk),
        .rst  (rst),
        .start(uart_start),
        .data (uart_data),
        .tx   (uart_tx),
        .busy (uart_busy)
    );

    assign time_rd_en = (state == ST_WAVE_READ);

    //-------------------------------------------------------------------------
    // HMI FSM
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            vpp_latched        <= 17'd0;
            vrms_latched       <= 16'd0;
            f1_index_latched   <= 12'd0;
            f1_hz_latched      <= 32'd0;
            amp_f1_latched     <= 32'd0;
            display_three_cycles_latched <= 1'b0;
            have_time_result   <= 1'b0;
            have_peak_result   <= 1'b0;
            vpp_active         <= 17'd0;
            vrms_active        <= 16'd0;
            f1_index_active    <= 12'd0;
            f1_hz_active       <= 32'd0;
            amp_f1_active      <= 32'd0;
            text_id             <= 2'd0;
            text_byte_index    <= 4'd0;
            text_digit_pos     <= 4'd0;
            text_term_index     <= 2'd0;
            time_rd_addr       <= {TIME_ADDR_WIDTH{1'b0}};
            wave_span           <= 32'd0;
            wave_phase_acc      <= 32'd0;
            wave_point_index    <= 9'd0;
            wave_y              <= 8'd0;
            wave_y_length       <= 2'd1;
            wave_y_index        <= 2'd0;
            wave_prefix_index   <= 4'd0;
            wave_term_index     <= 2'd0;
            wave_sample_negative<= 1'b0;
            wave_sample_reg     <= 16'sd0;
            div_num             <= 25'd0;
            div_den             <= 17'd0;
            div_quot            <= 25'd0;
            div_rem             <= 18'd0;
            div_count           <= 5'd0;
            span_div_num        <= {SPAN_DIV_BITS{1'b0}};
            span_div_quot       <= {SPAN_DIV_BITS{1'b0}};
            span_div_rem        <= 13'd0;
            span_div_count      <= 4'd0;
            span_div_den        <= 12'd0;
            addr_div_num        <= {ADDR_DIV_BITS{1'b0}};
            addr_div_quot       <= {ADDR_DIV_BITS{1'b0}};
            addr_div_rem        <= 10'd0;
            addr_div_count      <= 5'd0;
            busy                <= 1'b0;
            waveform_done       <= 1'b0;
            frame_release       <= 1'b0;
            measurement_valid   <= 1'b0;
        end
        else begin
            waveform_done <= 1'b0;
            measurement_valid <= 1'b0;

            // Results can arrive while the previous UART message is still being
            // sent. The two flags form a one-entry pending-result mailbox.
            if (time_result_valid) begin
                vpp_latched      <= vpp_in;
                vrms_latched     <= vrms_in;
                have_time_result <= 1'b1;
            end
            if (peak_result_valid) begin
                f1_index_latched <= f1_index_in;
                f1_hz_latched    <= f1_hz_in;
                amp_f1_latched   <= amp_f1_in;
                have_peak_result  <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    // Start only from flags already latched on a previous clock;
                    // this guarantees all four input value registers are stable.
                    if (have_time_result && have_peak_result) begin
                        // Preserve a result arriving on this same edge instead
                        // of clearing it after the input-latch logic above.
                        // This makes the one-entry mailbox lossless at the
                        // idle-to-conversion boundary.
                        have_time_result <= time_result_valid;
                        have_peak_result <= peak_result_valid;
                        vpp_active       <= vpp_latched;
                        vrms_active      <= vrms_latched;
                        f1_index_active  <= f1_index_latched;
                        f1_hz_active     <= f1_hz_latched;
                        amp_f1_active    <= amp_f1_latched;
                        display_three_cycles_latched <= display_three_cycles;
                        frame_release    <= 1'b0;
                        busy              <= 1'b1;
                        state             <= ST_CONV_START;
                    end
                end

                ST_CONV_START: begin
                    busy  <= 1'b1;
                    // bcd_start is high in this cycle and is sampled by all four
                    // converters at this edge.
                    // The active snapshot was loaded in the preceding ST_IDLE
                    // cycle, so this pulse is aligned with the displayed result
                    // registers rather than with the earlier frame completion.
                    measurement_valid <= 1'b1;
                    state <= ST_CONV_WAIT;
                end

                ST_CONV_WAIT: begin
                    busy <= 1'b1;
                    if (all_bcd_done) begin
                        text_id          <= 2'd0;
                        text_byte_index  <= 4'd0;
                        state             <= ST_TEXT_PREFIX;
                    end
                end

                ST_TEXT_PREFIX: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        if (text_byte_index == 4'd7) begin
                            text_digit_pos <= first_nonzero_digit(selected_bcd);
                            state           <= ST_TEXT_DIGITS;
                        end
                        else begin
                            text_byte_index <= text_byte_index + 1'b1;
                        end
                    end
                end

                ST_TEXT_DIGITS: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        if (text_digit_pos == 0) begin
                            state <= ST_TEXT_CLOSE;
                        end
                        else begin
                            text_digit_pos <= text_digit_pos - 1'b1;
                        end
                    end
                end

                ST_TEXT_CLOSE: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        text_term_index <= 2'd0;
                        state           <= ST_TEXT_TERM;
                    end
                end

                ST_TEXT_TERM: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        if (text_term_index == 2'd2) begin
                            if (text_id == 2'd3) begin
                                state <= ST_WAVE_PREP;
                            end
                            else begin
                                text_id         <= text_id + 1'b1;
                                text_byte_index <= 4'd0;
                                state            <= ST_TEXT_PREFIX;
                            end
                        end
                        else begin
                            text_term_index <= text_term_index + 1'b1;
                        end
                    end
                end

                ST_WAVE_PREP: begin
                    busy             <= 1'b1;
                    wave_phase_acc   <= 32'd0;
                    wave_point_index <= 9'd0;
                    time_rd_addr     <= {TIME_ADDR_WIDTH{1'b0}};
                    wave_prefix_index <= 4'd0;

                    if (f1_index_active == 0) begin
                        // No valid peak: display the complete frame.
                        wave_span <= FRAME_LENGTH - 1;
                        state     <= ST_WAVE_READ;
                    end
                    else begin
                        // Iteratively calculate N_cycle = FRAME_LENGTH / f1.
                        span_div_num   <= FRAME_LENGTH;
                        span_div_den   <= f1_index_active;
                        span_div_quot  <= {SPAN_DIV_BITS{1'b0}};
                        span_div_rem   <= 13'd0;
                        span_div_count <= 4'd0;
                        state          <= ST_WAVE_SPAN_DIV;
                    end
                end

                ST_WAVE_SPAN_DIV: begin
                    busy            <= 1'b1;
                    span_div_rem    <= span_div_rem_next;
                    span_div_quot   <= span_div_quot_next;

                    if (span_div_count == SPAN_DIV_BITS-1) begin
                        wave_span <= span_limited;
                        state     <= ST_WAVE_READ;
                    end
                    else begin
                        span_div_count <= span_div_count + 1'b1;
                    end
                end

                ST_WAVE_READ: begin
                    busy  <= 1'b1;
                    // time_rd_en is high for this cycle.  The BRAM output is
                    // registered, so capture it on the following state edge
                    // before doing any arithmetic on the sample.
                    state <= ST_WAVE_CAPTURE;
                end

                ST_WAVE_CAPTURE: begin
                    busy                  <= 1'b1;
                    wave_sample_reg      <= time_rd_data;
                    wave_sample_negative <= time_rd_data[15];
                    state                 <= ST_WAVE_PROCESS;
                end

                ST_WAVE_PROCESS: begin
                    busy <= 1'b1;

                    if (vpp_active == 0) begin
                        wave_y <= full_scale_y(wave_sample_reg);
                        if (full_scale_y(wave_sample_reg) >= 100)
                            wave_y_length <= 2'd3;
                        else if (full_scale_y(wave_sample_reg) >= 10)
                            wave_y_length <= 2'd2;
                        else
                            wave_y_length <= 2'd1;
                        wave_y_index      <= 2'd0;
                        wave_prefix_index <= 4'd0;
                        state             <= ST_WAVE_PREFIX;
                    end
                    else begin
                        div_num   <= wave_numerator;
                        div_den   <= vpp_active;
                        div_quot  <= 25'd0;
                        div_rem   <= 18'd0;
                        div_count <= 5'd0;
                        state     <= ST_WAVE_DIVIDE;
                    end
                end

                ST_WAVE_DIVIDE: begin
                    busy     <= 1'b1;
                    div_rem  <= div_rem_next;
                    div_quot <= div_quot_next;
                    if (div_count == 5'd24) begin
                        state <= ST_WAVE_Y_PREP;
                    end
                    else begin
                        div_count <= div_count + 1'b1;
                    end
                end

                ST_WAVE_Y_PREP: begin
                    busy <= 1'b1;
                    if (wave_sample_negative) begin
                        if (div_quot > 25'd127)
                            wave_y <= 8'd255;
                        else
                            wave_y <= 8'd128 + div_quot[7:0];
                    end
                    else begin
                        if (div_quot > 25'd128)
                            wave_y <= 8'd0;
                        else
                            wave_y <= 8'd128 - div_quot[7:0];
                    end

                    if (wave_sample_negative) begin
                        if (div_quot > 25'd127)
                            wave_y_length <= 2'd3;
                        else if ((8'd128 + div_quot[7:0]) >= 100)
                            wave_y_length <= 2'd3;
                        else if ((8'd128 + div_quot[7:0]) >= 10)
                            wave_y_length <= 2'd2;
                        else
                            wave_y_length <= 2'd1;
                    end
                    else begin
                        if (div_quot > 25'd128)
                            wave_y_length <= 2'd1;
                        else if ((8'd128 - div_quot[7:0]) >= 100)
                            wave_y_length <= 2'd3;
                        else if ((8'd128 - div_quot[7:0]) >= 10)
                            wave_y_length <= 2'd2;
                        else
                            wave_y_length <= 2'd1;
                    end
                    wave_y_index      <= 2'd0;
                    wave_prefix_index <= 4'd0;
                    state             <= ST_WAVE_PREFIX;
                end

                ST_WAVE_PREFIX: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        if (wave_prefix_index == 4'd7) begin
                            wave_y_index <= 2'd0;
                            state        <= ST_WAVE_DIGITS;
                        end
                        else begin
                            wave_prefix_index <= wave_prefix_index + 1'b1;
                        end
                    end
                end

                ST_WAVE_DIGITS: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        if (wave_y_index == wave_y_length - 1'b1) begin
                            wave_term_index <= 2'd0;
                            state            <= ST_WAVE_TERM;
                        end
                        else begin
                            wave_y_index <= wave_y_index + 1'b1;
                        end
                    end
                end

                ST_WAVE_TERM: begin
                    busy <= 1'b1;
                    if (uart_start) begin
                        if (wave_term_index == 2'd2) begin
                            if (wave_point_index == WAVE_POINTS-1) begin
                                waveform_done <= 1'b1;
                                // The last byte has been accepted by UART_Tx;
                                // the frame is no longer read by this FSM.
                                // Keep the level high until the next packet so
                                // AFE_Capture cannot miss the release event.
                                frame_release <= 1'b1;
                                busy          <= 1'b0;
                                state         <= ST_IDLE;
                            end
                            else begin
                                wave_point_index <= wave_point_index + 1'b1;
                                wave_phase_acc   <= wave_phase_acc + wave_span;
                                // Address = floor((point+1)*wave_span /
                                // (WAVE_POINTS-1)).
                                // Calculate it in a 23-cycle restoring divider
                                // so the 100 MHz critical path stays shallow.
                                addr_div_num   <= wave_phase_acc + wave_span;
                                addr_div_quot  <= {ADDR_DIV_BITS{1'b0}};
                                addr_div_rem   <= 10'd0;
                                addr_div_count <= 5'd0;
                                state          <= ST_WAVE_ADDR_DIV;
                            end
                        end
                        else begin
                            wave_term_index <= wave_term_index + 1'b1;
                        end
                    end
                end

                ST_WAVE_ADDR_DIV: begin
                    busy          <= 1'b1;
                    addr_div_rem  <= addr_div_rem_next;
                    addr_div_quot <= addr_div_quot_next;

                    if (addr_div_count == ADDR_DIV_BITS-1) begin
                        if (addr_div_quot_next >= FRAME_LENGTH)
                            time_rd_addr <= FRAME_LENGTH - 1;
                        else
                            time_rd_addr <= addr_div_quot_next[TIME_ADDR_WIDTH-1:0];
                        state <= ST_WAVE_READ;
                    end
                    else begin
                        addr_div_count <= addr_div_count + 1'b1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule


//==============================================================================
// UART_Tx
//------------------------------------------------------------------------------
// 8-N-1 UART transmitter. CLKS_PER_BIT=868 at 100 MHz / 115200 bps, giving a
// baud error below 0.01%. The start bit is driven immediately when accepted;
// each following bit is held for exactly CLKS_PER_BIT clocks.
//==============================================================================
module UART_Tx #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);

    localparam integer CLKS_PER_BIT_RAW = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer CLKS_PER_BIT = (CLKS_PER_BIT_RAW < 1) ? 1 : CLKS_PER_BIT_RAW;

    reg [15:0] baud_count;
    reg [3:0]  bit_index;
    reg [9:0]  shift_reg;

    always @(posedge clk) begin
        if (rst) begin
            tx         <= 1'b1;
            busy       <= 1'b0;
            baud_count <= 16'd0;
            bit_index  <= 4'd0;
            shift_reg  <= 10'h3ff;
        end
        else if (!busy) begin
            tx         <= 1'b1;
            baud_count <= 16'd0;
            if (start) begin
                // [9:1] = stop/data[7:0], [0] = start.
                shift_reg  <= {1'b1, data, 1'b0};
                bit_index  <= 4'd0;
                tx         <= 1'b0;
                busy       <= 1'b1;
            end
        end
        else begin
            if (baud_count == CLKS_PER_BIT-1) begin
                baud_count <= 16'd0;
                if (bit_index == 4'd9) begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                end
                else begin
                    tx        <= shift_reg[1];
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    bit_index <= bit_index + 1'b1;
                end
            end
            else begin
                baud_count <= baud_count + 1'b1;
            end
        end
    end

endmodule
