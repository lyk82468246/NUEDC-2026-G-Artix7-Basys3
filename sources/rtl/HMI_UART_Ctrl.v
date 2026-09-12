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
// 分时状态机，400 点发送期间不会阻塞采集、FFT 或峰值搜索硬件。
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

    // HMI 专用时域 BRAM 同步读口。
    output wire                                  time_rd_en,
    output reg  [TIME_ADDR_WIDTH-1:0]            time_rd_addr,
    input  wire signed [15:0]                    time_rd_data,

    output wire                                  uart_tx,
    output reg                                  busy,
    output reg                                  waveform_done
);

    //-------------------------------------------------------------------------
    // Result latches and four parallel binary-to-BCD converters
    //-------------------------------------------------------------------------
    reg [16:0] vpp_latched;
    reg [15:0] vrms_latched;
    reg [11:0] f1_index_latched;
    reg [31:0] f1_hz_latched;
    reg [31:0] amp_f1_latched;
    reg        have_time_result;
    reg        have_peak_result;

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
        .binary_in({15'd0, vpp_latched}),
        .bcd_out  (vpp_bcd),
        .busy     (),
        .done     (vpp_bcd_done)
    );

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_vrms (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in({16'd0, vrms_latched}),
        .bcd_out  (vrms_bcd),
        .busy     (),
        .done     (vrms_bcd_done)
    );

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_f1 (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in(f1_hz_latched),
        .bcd_out  (f1_bcd),
        .busy     (),
        .done     (f1_bcd_done)
    );

    BIN2BCD #(.INPUT_WIDTH(32), .DIGITS(10)) u_bin2bcd_amp_f1 (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in(amp_f1_latched),
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
    function [39:0] select_bcd;
        input [1:0] id;
        begin
            case (id)
                2'd0: select_bcd = vpp_bcd;
                2'd1: select_bcd = vrms_bcd;
                2'd2: select_bcd = f1_bcd;
                default: select_bcd = amp_f1_bcd;
            endcase
        end
    endfunction

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
        reg [31:0] n_cycle;
        reg [31:0] total_samples;
        begin
            if (index == 0)
                n_cycle = FRAME_LENGTH;
            else
                n_cycle = FRAME_LENGTH / index;

            if (n_cycle == 0)
                n_cycle = 1;

            total_samples = n_cycle * DISPLAY_CYCLES;
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
    function [7:0] full_scale_y;
        input signed [15:0] sample;
        reg signed [16:0] sample_ext;
        reg [16:0] sample_unsigned;
        reg [24:0] scaled;
        begin
            sample_ext      = sample;
            sample_unsigned = sample_ext + 17'sd32768;
            scaled          = (sample_unsigned * 17'd255 + 25'd32768) >> 16;
            if (scaled > 255)
                full_scale_y = 8'd255;
            else
                full_scale_y = scaled[7:0];
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
    localparam [4:0] ST_WAVE_PREP    = 5'd7;
    localparam [4:0] ST_WAVE_READ    = 5'd8;
    localparam [4:0] ST_WAVE_PROCESS  = 5'd9;
    localparam [4:0] ST_WAVE_DIVIDE   = 5'd10;
    localparam [4:0] ST_WAVE_Y_PREP   = 5'd11;
    localparam [4:0] ST_WAVE_PREFIX   = 5'd12;
    localparam [4:0] ST_WAVE_DIGITS   = 5'd13;
    localparam [4:0] ST_WAVE_TERM     = 5'd14;

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
    assign wave_abs_sample = time_rd_data[15] ?
                             (~{1'b0, time_rd_data} + 17'd1) :
                             {1'b0, time_rd_data};
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

    wire [39:0] selected_bcd;
    assign selected_bcd = select_bcd(text_id);

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
            have_time_result   <= 1'b0;
            have_peak_result   <= 1'b0;
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
            div_num             <= 25'd0;
            div_den             <= 17'd0;
            div_quot            <= 25'd0;
            div_rem             <= 18'd0;
            div_count           <= 5'd0;
            busy                <= 1'b0;
            waveform_done       <= 1'b0;
        end
        else begin
            waveform_done <= 1'b0;

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
                        busy              <= 1'b1;
                        state             <= ST_CONV_START;
                    end
                end

                ST_CONV_START: begin
                    busy  <= 1'b1;
                    // bcd_start is high in this cycle and is sampled by all four
                    // converters at this edge.
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
                    wave_span        <= calculate_wave_span(f1_index_latched);
                    wave_phase_acc   <= 32'd0;
                    wave_point_index <= 9'd0;
                    time_rd_addr     <= {TIME_ADDR_WIDTH{1'b0}};
                    wave_prefix_index<= 4'd0;
                    state            <= ST_WAVE_READ;
                end

                ST_WAVE_READ: begin
                    busy  <= 1'b1;
                    // time_rd_en is high for this cycle. The next state consumes
                    // the synchronous BRAM output.
                    state <= ST_WAVE_PROCESS;
                end

                ST_WAVE_PROCESS: begin
                    busy                 <= 1'b1;
                    wave_sample_negative <= time_rd_data[15];

                    if (vpp_latched == 0) begin
                        wave_y <= full_scale_y(time_rd_data);
                        if (full_scale_y(time_rd_data) >= 100)
                            wave_y_length <= 2'd3;
                        else if (full_scale_y(time_rd_data) >= 10)
                            wave_y_length <= 2'd2;
                        else
                            wave_y_length <= 2'd1;
                        wave_y_index      <= 2'd0;
                        wave_prefix_index <= 4'd0;
                        state             <= ST_WAVE_PREFIX;
                    end
                    else begin
                        div_num   <= wave_numerator;
                        div_den   <= vpp_latched;
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
                                busy          <= 1'b0;
                                state         <= ST_IDLE;
                            end
                            else begin
                                wave_point_index <= wave_point_index + 1'b1;
                                wave_phase_acc   <= wave_phase_acc + wave_span;
                                time_rd_addr     <= address_from_phase(
                                                       wave_phase_acc + wave_span);
                                state             <= ST_WAVE_READ;
                            end
                        end
                        else begin
                            wave_term_index <= wave_term_index + 1'b1;
                        end
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
