`timescale 1ns / 1ps

//==============================================================================
// Peak_Search
//------------------------------------------------------------------------------
// 在 BRAM_FreqDomain 的正频率部分搜索最大幅值。
//
// 扫描范围为 bin 10..4000（含首尾），避开 DC 和靠近 Nyquist 的边界噪声。
// FFT_Processor 完整排空 8192 个 FFT/CORDIC 输出后翻转 frame_done_toggle；
// 本模块经过两级同步器检测该事件，再使用同步读 BRAM 的
// READ_REQUEST -> PROCESS 两状态逐点比较。
//
// f1_hz = max_index * 500。amp_f1 使用 MAG_SCALE_FACTOR 做预留的整数补偿，
// 默认值 1 表示保持 CORDIC/FFT 的原始幅值刻度。若后续标定得到非整数
// 比例，建议把该模块前面改成 Q 格式乘法；此处先保留简单的整数参数。
//==============================================================================
module Peak_Search #(
    parameter integer FREQ_DEPTH       = 4096,
    parameter integer FREQ_ADDR_WIDTH  = 12,
    parameter integer SEARCH_START     = 10,
    parameter integer SEARCH_END       = 4000,
    parameter integer PEAK_THRESHOLD   = 0,
    parameter integer MAG_SCALE_FACTOR = 1
)(
    input  wire                         calc_clk,
    input  wire                         rst,

    input  wire                         frame_done_toggle,

    output reg  [FREQ_ADDR_WIDTH-1:0]  freq_rd_addr,
    output wire                         freq_rd_en,
    input  wire [31:0]                  freq_rd_data,

    output reg  [FREQ_ADDR_WIDTH-1:0]  max_index,
    output reg  [31:0]                  f1_hz,
    output reg  [31:0]                  amp_f1,
    output reg                          result_valid,
    output reg                          busy
);

    //-------------------------------------------------------------------------
    // Completion toggle synchronizer
    //-------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg frame_toggle_sync_ff1;
    (* ASYNC_REG = "TRUE" *) reg frame_toggle_sync_ff2;
    reg frame_toggle_sync_d;
    wire new_frame_event;

    assign new_frame_event = frame_toggle_sync_ff2 ^ frame_toggle_sync_d;

    always @(posedge calc_clk) begin
        if (rst) begin
            frame_toggle_sync_ff1 <= 1'b0;
            frame_toggle_sync_ff2 <= 1'b0;
            frame_toggle_sync_d   <= 1'b0;
        end
        else begin
            frame_toggle_sync_ff1 <= frame_done_toggle;
            frame_toggle_sync_ff2 <= frame_toggle_sync_ff1;
            frame_toggle_sync_d   <= frame_toggle_sync_ff2;
        end
    end

    //-------------------------------------------------------------------------
    // Helper functions
    //-------------------------------------------------------------------------
    function [31:0] scale_magnitude;
        input [31:0] magnitude;
        reg [63:0] product;
        begin
            // Explicitly widen the first operand.  Without this cast a
            // 32-bit-by-integer multiply can be evaluated at only 32 bits by
            // Verilog, making the saturation check ineffective for factors
            // greater than one.
            product = {32'd0, magnitude} * MAG_SCALE_FACTOR;
            if (|product[63:32])
                scale_magnitude = 32'hffff_ffff;
            else
                scale_magnitude = product[31:0];
        end
    endfunction

    function [31:0] index_to_frequency;
        input [FREQ_ADDR_WIDTH-1:0] index;
        reg [31:0] index_ext;
        begin
            index_ext = index;
            // 500 = 512 - 8 - 4; this avoids a general-purpose divider.
            index_to_frequency = (index_ext << 9) -
                                 (index_ext << 3) -
                                 (index_ext << 2);
        end
    endfunction

    //-------------------------------------------------------------------------
    // Synchronous BRAM scan FSM
    //-------------------------------------------------------------------------
    // Keep the integer parameters in explicitly sized vectors before using
    // them in comparisons/assignments.  This avoids tool-dependent part-select
    // parsing such as SEARCH_START[FREQ_ADDR_WIDTH-1:0].
    localparam [FREQ_ADDR_WIDTH-1:0] SEARCH_START_ADDR = SEARCH_START;
    localparam [FREQ_ADDR_WIDTH-1:0] SEARCH_END_ADDR   = SEARCH_END;

    localparam [1:0] ST_IDLE         = 2'd0;
    localparam [1:0] ST_READ_REQUEST = 2'd1;
    localparam [1:0] ST_PROCESS      = 2'd2;

    reg [1:0] state;
    reg [FREQ_ADDR_WIDTH-1:0] scan_addr;
    reg [31:0] max_magnitude;

    wire candidate_is_larger;
    assign candidate_is_larger =
        (freq_rd_data >= PEAK_THRESHOLD) &&
        (freq_rd_data > max_magnitude);

    assign freq_rd_en = (state == ST_READ_REQUEST);

    always @(posedge calc_clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            scan_addr      <= {FREQ_ADDR_WIDTH{1'b0}};
            freq_rd_addr   <= {FREQ_ADDR_WIDTH{1'b0}};
            max_magnitude  <= 32'd0;
            max_index      <= {FREQ_ADDR_WIDTH{1'b0}};
            f1_hz          <= 32'd0;
            amp_f1         <= 32'd0;
            result_valid   <= 1'b0;
            busy           <= 1'b0;
        end
        else begin
            result_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (new_frame_event) begin
                        busy         <= 1'b1;
                        scan_addr    <= SEARCH_START_ADDR;
                        freq_rd_addr <= SEARCH_START_ADDR;
                        max_magnitude <= 32'd0;
                        max_index      <= {FREQ_ADDR_WIDTH{1'b0}};
                        state          <= ST_READ_REQUEST;
                    end
                end

                ST_READ_REQUEST: begin
                    busy  <= 1'b1;
                    // freq_rd_en is high for this state; data is available in
                    // ST_PROCESS after the BRAM clock edge.
                    state <= ST_PROCESS;
                end

                ST_PROCESS: begin
                    busy <= 1'b1;

                    if (candidate_is_larger) begin
                        max_magnitude <= freq_rd_data;
                        max_index     <= scan_addr;
                    end

                    if (scan_addr == SEARCH_END_ADDR) begin
                        // Include the last sample in the reported result even
                        // though max_magnitude is updated by nonblocking logic.
                        if (candidate_is_larger) begin
                            amp_f1 <= scale_magnitude(freq_rd_data);
                            f1_hz  <= index_to_frequency(scan_addr);
                        end
                        else begin
                            amp_f1 <= scale_magnitude(max_magnitude);
                            f1_hz  <= index_to_frequency(max_index);
                        end
                        result_valid <= 1'b1;
                        busy         <= 1'b0;
                        state        <= ST_IDLE;
                    end
                    else begin
                        scan_addr    <= scan_addr + 1'b1;
                        freq_rd_addr <= scan_addr + 1'b1;
                        state        <= ST_READ_REQUEST;
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
