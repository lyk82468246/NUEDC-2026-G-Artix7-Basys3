`timescale 1ns / 1ps

//==============================================================================
// Time_Domain_Calc
//------------------------------------------------------------------------------
// 功能：
//   在 calc_clk 域遍历 BRAM_TimeDomain 的一帧采样，计算：
//     Vpp  = max(sample) - min(sample)
//     Vrms = sqrt(sum(sample^2) / 8192)
//
// 重要约定：
//   * bram_rd_data 来自一个“同步读、1 个时钟周期读延迟”的双口 BRAM；
//   * frame_done_toggle 来自 adc_clk 域，内部使用两级同步器和 toggle 边沿检测；
//   * 样本按有符号 two's-complement 解释；平方结果一定为非负无符号数；
//   * 8192 = 2^13，因此均方值使用右移 13 bit，之后送入 CORDIC Square Root。
//
// CORDIC IP 约定：
//   工程中存在名为 cordic_sqrt_rms 的 CORDIC IP，配置为：
//     Square Root / Unsigned Integer / Input 32 bit / 自动派生 Output 17 bit /
//     Blocking / output tready enabled / aresetn enabled。
//==============================================================================
module Time_Domain_Calc #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer FRAME_LENGTH = 8192,
    parameter integer ADDR_WIDTH   = 13,
    // 16x16 square 为 32 bit；再累加 8192 个样本需要 13 bit 增长。
    parameter integer SUM_WIDTH    = 44
)(
    input  wire                           calc_clk,
    input  wire                           rst,                 // 高有效同步复位

    // 来自 AFE_Capture 的跨域帧完成标志。
    input  wire                           frame_done_toggle,

    // BRAM 读端口；rd_en 由本模块状态机产生。
    output reg  [ADDR_WIDTH-1:0]          bram_rd_addr,
    output wire                           bram_rd_en,
    input  wire signed [DATA_WIDTH-1:0]   bram_rd_data,

    // 结果输出。
    output reg  [DATA_WIDTH:0]             vpp_out,
    output reg  [DATA_WIDTH-1:0]           vrms_out,
    output reg  [31:0]                     mean_square_out,
    output reg                             result_valid,
    output reg                             busy
);

    //-------------------------------------------------------------------------
    // frame_done_toggle CDC
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
    // BRAM read / statistic datapath
    //-------------------------------------------------------------------------
    localparam [ADDR_WIDTH-1:0] LAST_SAMPLE_ADDR = FRAME_LENGTH - 1;
    localparam integer RMS_DIV_SHIFT = 13;

    // 读请求状态持续一个 calc_clk 周期；下一状态开始时，BRAM 输出已更新。
    localparam [2:0] ST_IDLE         = 3'd0;
    localparam [2:0] ST_READ_REQUEST = 3'd1;
    localparam [2:0] ST_PROCESS      = 3'd2;
    localparam [2:0] ST_CORDIC_SEND  = 3'd3;
    localparam [2:0] ST_CORDIC_WAIT  = 3'd4;

    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] sample_count;

    reg signed [DATA_WIDTH-1:0] max_value_s;
    reg signed [DATA_WIDTH-1:0] min_value_s;
    reg        [SUM_WIDTH-1:0]  sum_square;

    // bram_rd_en 为组合译码信号：进入 READ_REQUEST 后，BRAM 在该周期结束
    // 的时钟沿采样地址，下一拍进入 PROCESS 时数据可被逻辑使用。
    assign bram_rd_en = (state == ST_READ_REQUEST);

    // signed sample * signed sample。DATA_WIDTH=16 时由 DSP Slice 推断 16x16。
    wire signed [(2*DATA_WIDTH)-1:0] sample_product_s;
    wire        [(2*DATA_WIDTH)-1:0] sample_square;
    wire        [SUM_WIDTH-1:0]      sample_square_ext;
    wire        [SUM_WIDTH-1:0]      sum_square_next;
    wire        [SUM_WIDTH-1:0]      mean_square_wide;

    assign sample_product_s = $signed(bram_rd_data) * $signed(bram_rd_data);
    assign sample_square    = sample_product_s[(2*DATA_WIDTH)-1:0];
    assign sample_square_ext = {{(SUM_WIDTH-(2*DATA_WIDTH)){1'b0}},
                                 sample_square};
    assign sum_square_next  = sum_square + sample_square_ext;
    assign mean_square_wide = sum_square_next >> RMS_DIV_SHIFT;

    // 当前样本参与比较后的候选 max/min。sample_count==0 时在 FSM 中单独初始化，
    // 因而不会使用复位值 0 污染一帧的最大/最小值。
    wire signed [DATA_WIDTH-1:0] max_after_sample_s;
    wire signed [DATA_WIDTH-1:0] min_after_sample_s;
    wire signed [DATA_WIDTH:0]   vpp_candidate_s;

    assign max_after_sample_s = (bram_rd_data > max_value_s) ?
                                bram_rd_data : max_value_s;
    assign min_after_sample_s = (bram_rd_data < min_value_s) ?
                                bram_rd_data : min_value_s;
    assign vpp_candidate_s =
        $signed({max_after_sample_s[DATA_WIDTH-1], max_after_sample_s}) -
        $signed({min_after_sample_s[DATA_WIDTH-1], min_after_sample_s});

    //-------------------------------------------------------------------------
    // CORDIC Square Root AXI4-Stream interface
    //-------------------------------------------------------------------------
    reg  [31:0] cordic_s_axis_tdata;
    reg         cordic_s_axis_tvalid;
    wire        cordic_s_axis_tready;
    wire        cordic_m_axis_tvalid;
    // Vivado 2025.2 的 CORDIC Square Root 会把 32-bit 输入的输出宽度
    // 自动派生为 17 bit，并按 AXI4-Stream 字节对齐为 24-bit TDATA。
    // 当前有效 RMS 范围不超过 32768，因此取低 16 bit 输出即可；保留
    // 完整 24-bit 总线宽度可避免与生成的 IP 例化端口发生截断连接。
    localparam integer CORDIC_TDATA_WIDTH = 24;
    wire [CORDIC_TDATA_WIDTH-1:0] cordic_m_axis_tdata;

    cordic_sqrt_rms u_cordic_sqrt_rms (
        .aclk                    (calc_clk),
        .aresetn                 (~rst),
        .s_axis_cartesian_tvalid(cordic_s_axis_tvalid),
        .s_axis_cartesian_tready(cordic_s_axis_tready),
        .s_axis_cartesian_tdata (cordic_s_axis_tdata),
        .m_axis_dout_tvalid     (cordic_m_axis_tvalid),
        .m_axis_dout_tready     (1'b1),
        .m_axis_dout_tdata      (cordic_m_axis_tdata)
    );

    //-------------------------------------------------------------------------
    // FSM
    //-------------------------------------------------------------------------
    always @(posedge calc_clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            bram_rd_addr       <= {ADDR_WIDTH{1'b0}};
            sample_count       <= {ADDR_WIDTH{1'b0}};
            max_value_s        <= {DATA_WIDTH{1'b0}};
            min_value_s        <= {DATA_WIDTH{1'b0}};
            sum_square         <= {SUM_WIDTH{1'b0}};
            cordic_s_axis_tdata  <= 32'd0;
            cordic_s_axis_tvalid <= 1'b0;
            vpp_out             <= {(DATA_WIDTH+1){1'b0}};
            vrms_out            <= {DATA_WIDTH{1'b0}};
            mean_square_out     <= 32'd0;
            result_valid        <= 1'b0;
            busy                <= 1'b0;
        end
        else begin
            // result_valid 只在 CORDIC 输出有效的一个时钟周期内拉高。
            result_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (new_frame_event) begin
                        busy          <= 1'b1;
                        sample_count  <= {ADDR_WIDTH{1'b0}};
                        bram_rd_addr  <= {ADDR_WIDTH{1'b0}};
                        max_value_s   <= {DATA_WIDTH{1'b0}};
                        min_value_s   <= {DATA_WIDTH{1'b0}};
                        sum_square    <= {SUM_WIDTH{1'b0}};
                        state         <= ST_READ_REQUEST;
                    end
                end

                ST_READ_REQUEST: begin
                    // bram_rd_en=1 已由组合逻辑保持一个周期；下一状态处理读数据。
                    state <= ST_PROCESS;
                end

                ST_PROCESS: begin
                    // 在该状态，bram_rd_data 是当前 sample_count 地址的数据。
                    sum_square <= sum_square_next;

                    if (sample_count == {ADDR_WIDTH{1'b0}}) begin
                        max_value_s <= bram_rd_data;
                        min_value_s <= bram_rd_data;
                    end
                    else begin
                        max_value_s <= max_after_sample_s;
                        min_value_s <= min_after_sample_s;
                    end

                    if (sample_count == LAST_SAMPLE_ADDR) begin
                        // 使用包含“最后一个样本”的 sum_square_next 和 max/min。
                        if (sample_count == {ADDR_WIDTH{1'b0}})
                            vpp_out <= {(DATA_WIDTH+1){1'b0}};
                        else
                            vpp_out <= vpp_candidate_s[DATA_WIDTH:0];

                        mean_square_out      <= mean_square_wide[31:0];
                        // CORDIC 配置为 Unsigned Integer。均方值的物理上限为
                        // 2^30，故放入 32-bit X_IN 不会损失有效位。
                        cordic_s_axis_tdata  <= mean_square_wide[31:0];
                        cordic_s_axis_tvalid <= 1'b1;
                        state                <= ST_CORDIC_SEND;
                    end
                    else begin
                        sample_count <= sample_count + 1'b1;
                        bram_rd_addr <= sample_count + 1'b1;
                        state        <= ST_READ_REQUEST;
                    end
                end

                ST_CORDIC_SEND: begin
                    // valid 在上一状态已经置 1；若 IP 尚未 ready，则保持 valid 和 data。
                    if (cordic_s_axis_tready) begin
                        cordic_s_axis_tvalid <= 1'b0;
                        state                <= ST_CORDIC_WAIT;
                    end
                end

                ST_CORDIC_WAIT: begin
                    if (cordic_m_axis_tvalid) begin
                        vrms_out     <= cordic_m_axis_tdata[DATA_WIDTH-1:0];
                        result_valid <= 1'b1;
                        busy          <= 1'b0;
                        state         <= ST_IDLE;
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
