`timescale 1ns / 1ps

//==============================================================================
// FFT_Processor
//------------------------------------------------------------------------------
// 一帧时域数据的平顶窗加窗、8192 点 XFFT 以及频谱幅值计算。
//
// 数据路径：
//   BRAM_TimeDomain(rd2)
//       -> FlatTop_Window_ROM
//       -> 16 bit signed Q1.15 乘法并右移 15 bit
//       -> xfft_8192（16 bit input, unscaled, 30 bit/component output）
//       -> cordic_translate_mag（SignedFraction，30 -> 31 bit）
//       -> BRAM_FreqDomain 写端口（只保存 bin 0..4095）
//
// 重要的 AXI4-Stream 约束：
//   1. 配置通道在 config 握手前保持 TVALID 和 TDATA 不变；
//   2. FFT 输入通道在 TREADY 为 0 时保持 TVALID、TDATA、TLAST 不变；
//   3. FFT 输出使用一个寄存器级的 skid buffer 送入 CORDIC，只有在该
//      buffer 可接受新数据时才拉高 m_axis_data_tready；
//   4. CORDIC 输出 tready 固定为 1，写 BRAM 和计数器只在真实握手时更新。
//
// XFFT 9.1 的非实时 AXI 端口（由 setup_fft_uart.tcl 生成）是：
//   s_axis_config_tdata  [7:0]
//   s_axis_data_tdata    [31:0]  = {XN_IM padded, XN_RE padded}
//   m_axis_data_tdata    [63:0]  = {XK_IM padded, XK_RE padded}
//   s_axis_data_tlast / m_axis_data_tlast 均存在。
// 未缩放 8192 点 FFT 的有效分量宽度为 16 + log2(8192) + 1 = 30 bit。
//==============================================================================
module FFT_Processor #(
    parameter integer DATA_WIDTH                  = 16,
    parameter integer FRAME_LENGTH                = 8192,
    parameter integer ADDR_WIDTH                  = 13,
    parameter integer FREQ_DEPTH                  = 4096,
    parameter integer FREQ_ADDR_WIDTH             = 12,
    parameter integer WINDOW_FRAC_BITS            = 15,
    parameter integer FFT_INPUT_TDATA_WIDTH       = 32,
    parameter integer FFT_OUTPUT_COMPONENT_WIDTH  = 30,
    parameter integer FFT_OUTPUT_TDATA_WIDTH      = 64,
    parameter integer CORDIC_INPUT_WIDTH          = 30,
    parameter integer CORDIC_OUTPUT_WIDTH         = 31,
    parameter integer CORDIC_INPUT_TDATA_WIDTH    = 64,
    parameter integer CORDIC_OUTPUT_TDATA_WIDTH   = 64
)(
    input  wire                                  calc_clk,
    input  wire                                  rst,                 // 高有效同步复位

    // AFE_Capture 在 adc_clk 域翻转；这里使用 toggle CDC 检测新帧。
    input  wire                                  frame_done_toggle,

    // BRAM_TimeDomain 的 FFT 专用同步读口。
    output reg  [ADDR_WIDTH-1:0]                 time_rd_addr,
    output wire                                  time_rd_en,
    input  wire signed [DATA_WIDTH-1:0]          time_rd_data,

    // BRAM_FreqDomain 写端口。
    output reg  [FREQ_ADDR_WIDTH-1:0]             freq_wr_addr,
    output reg                                   freq_wr_en,
    output reg  [31:0]                            freq_wr_data,
    output reg                                   freq_frame_done_toggle,
    output reg                                   freq_frame_done_pulse,

    (* keep = "true" *) output reg              frame_valid,
    output reg                                   busy
);

    localparam [ADDR_WIDTH-1:0] LAST_SAMPLE_ADDR = FRAME_LENGTH - 1;
    localparam [12:0]            LAST_FFT_BIN     = FRAME_LENGTH - 1;

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
    // State machine and synchronized memory reads
    //-------------------------------------------------------------------------
    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_CONFIG       = 4'd1;
    localparam [3:0] ST_READ_REQUEST = 4'd2;
    localparam [3:0] ST_PREPARE      = 4'd3;
    localparam [3:0] ST_SEND         = 4'd4;
    localparam [3:0] ST_OUTPUT       = 4'd5;
    localparam [3:0] ST_DONE         = 4'd6;

    reg [3:0] state;
    reg [ADDR_WIDTH-1:0] sample_count;
    reg [12:0]            cordic_output_count;

    assign time_rd_en = (state == ST_READ_REQUEST);

    //-------------------------------------------------------------------------
    // Flat-top ROM and fixed-point window multiply
    //-------------------------------------------------------------------------
    wire                                  window_rom_en;
    wire [ADDR_WIDTH-1:0]                 window_rom_addr;
    wire signed [DATA_WIDTH-1:0]          window_rom_data;

    assign window_rom_en   = (state == ST_READ_REQUEST);
    assign window_rom_addr = time_rd_addr;

    FlatTop_Window_ROM #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_flat_top_window_rom (
        .clk (calc_clk),
        .en  (window_rom_en),
        .addr(window_rom_addr),
        .data(window_rom_data)
    );

    // time sample is integer-like signed data; window coefficient is Q1.15.
    // The arithmetic right shift restores the original sample scale.
    wire signed [(2*DATA_WIDTH)-1:0] window_product_s;
    wire signed [(2*DATA_WIDTH)-1:0] window_shifted_s;
    wire signed [DATA_WIDTH-1:0]       windowed_sample_s;

    assign window_product_s = $signed(time_rd_data) * $signed(window_rom_data);
    assign window_shifted_s = window_product_s >>> WINDOW_FRAC_BITS;

    // 16 bit saturation is retained even though the selected coefficient range
    // normally cannot overflow. It protects the wrapper if a replacement ROM
    // contains a coefficient slightly above unity.
    assign windowed_sample_s =
        (window_shifted_s > 32'sd32767)  ? 16'sh7fff :
        (window_shifted_s < -32'sd32768) ? 16'sh8000 :
                                           window_shifted_s[DATA_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // XFFT AXI4-Stream interfaces
    //-------------------------------------------------------------------------
    reg  [7:0]                   fft_config_tdata;
    reg                          fft_config_tvalid;
    wire                         fft_config_tready;

    reg  [FFT_INPUT_TDATA_WIDTH-1:0]  fft_s_axis_tdata;
    reg                          fft_s_axis_tvalid;
    reg                          fft_s_axis_tlast;
    wire                         fft_s_axis_tready;

    wire [FFT_OUTPUT_TDATA_WIDTH-1:0] fft_m_axis_tdata;
    wire                         fft_m_axis_tvalid;
    wire                         fft_m_axis_tlast;
    wire                         fft_m_axis_tready;

    // With fixed transform length, unscaled arithmetic and a forward transform,
    // only FWD_INV is present in the 8-bit configuration bus. Bit 0 = forward.
    localparam [7:0] FFT_FORWARD_CONFIG = 8'h01;

    wire event_frame_started;
    wire event_tlast_unexpected;
    wire event_tlast_missing;
    wire event_status_channel_halt;
    wire event_data_in_channel_halt;
    wire event_data_out_channel_halt;

    xfft_8192 u_xfft_8192 (
        .aclk                    (calc_clk),
        .aresetn                 (~rst),
        .s_axis_config_tdata    (fft_config_tdata),
        .s_axis_config_tvalid   (fft_config_tvalid),
        .s_axis_config_tready   (fft_config_tready),
        .s_axis_data_tdata      (fft_s_axis_tdata),
        .s_axis_data_tvalid     (fft_s_axis_tvalid),
        .s_axis_data_tready     (fft_s_axis_tready),
        .s_axis_data_tlast      (fft_s_axis_tlast),
        .m_axis_data_tdata      (fft_m_axis_tdata),
        .m_axis_data_tvalid     (fft_m_axis_tvalid),
        .m_axis_data_tready     (fft_m_axis_tready),
        .m_axis_data_tlast      (fft_m_axis_tlast),
        .event_frame_started    (event_frame_started),
        .event_tlast_unexpected (event_tlast_unexpected),
        .event_tlast_missing    (event_tlast_missing),
        .event_status_channel_halt(event_status_channel_halt),
        .event_data_in_channel_halt(event_data_in_channel_halt),
        .event_data_out_channel_halt(event_data_out_channel_halt)
    );

    //-------------------------------------------------------------------------
    // FFT output -> CORDIC input one-entry skid buffer
    //-------------------------------------------------------------------------
    reg  [CORDIC_INPUT_TDATA_WIDTH-1:0] cordic_s_axis_tdata;
    reg                                  cordic_s_axis_tvalid;
    wire                                 cordic_s_axis_tready;

    wire [CORDIC_OUTPUT_TDATA_WIDTH-1:0] cordic_m_axis_tdata;
    wire                                  cordic_m_axis_tvalid;

    // XFFT stores each component in a 32-bit byte-aligned field. The valid
    // 30-bit component is in bits [29:0] and [61:32], respectively.
    wire signed [FFT_OUTPUT_COMPONENT_WIDTH-1:0] fft_re_s;
    wire signed [FFT_OUTPUT_COMPONENT_WIDTH-1:0] fft_im_s;
    assign fft_re_s = $signed(fft_m_axis_tdata[FFT_OUTPUT_COMPONENT_WIDTH-1:0]);
    assign fft_im_s = $signed(fft_m_axis_tdata[32 +: FFT_OUTPUT_COMPONENT_WIDTH]);

    // CORDIC Translate uses SignedFraction (two integer bits). Dividing the
    // unscaled FFT component by two before presenting it to a 30-bit
    // Q2.28-like input maps the maximum possible 30-bit FFT value into [-1,1].
    // With a 31-bit output (Q2.29-like), this alignment makes the output raw
    // magnitude numerically close to sqrt(I^2+Q^2) in the original FFT scale.
    wire signed [CORDIC_INPUT_WIDTH-1:0] cordic_x_s;
    wire signed [CORDIC_INPUT_WIDTH-1:0] cordic_y_s;
    wire [31:0] cordic_x_padded;
    wire [31:0] cordic_y_padded;

    assign cordic_x_s = fft_re_s >>> 1;
    assign cordic_y_s = fft_im_s >>> 1;
    assign cordic_x_padded = {{(32-CORDIC_INPUT_WIDTH){cordic_x_s[CORDIC_INPUT_WIDTH-1]}},
                               cordic_x_s};
    assign cordic_y_padded = {{(32-CORDIC_INPUT_WIDTH){cordic_y_s[CORDIC_INPUT_WIDTH-1]}},
                               cordic_y_s};

    // CORDIC Cartesian TDATA packs X_IN in the least-significant field and
    // Y_IN in the next byte-aligned field.
    wire [CORDIC_INPUT_TDATA_WIDTH-1:0] cordic_input_from_fft;
    assign cordic_input_from_fft = {cordic_y_padded, cordic_x_padded};

    cordic_translate_mag u_cordic_translate_mag (
        .aclk                    (calc_clk),
        .aresetn                 (~rst),
        .s_axis_cartesian_tvalid(cordic_s_axis_tvalid),
        .s_axis_cartesian_tready(cordic_s_axis_tready),
        .s_axis_cartesian_tdata (cordic_s_axis_tdata),
        .m_axis_dout_tvalid     (cordic_m_axis_tvalid),
        .m_axis_dout_tready     (1'b1),
        .m_axis_dout_tdata      (cordic_m_axis_tdata)
    );

    // If the skid buffer is empty, or its current item will be consumed in this
    // cycle, FFT output can be accepted. This is the standard one-entry ready
    // equation and prevents data loss if CORDIC ever inserts back-pressure.
    assign fft_m_axis_tready =
        (state == ST_OUTPUT) &&
        ((!cordic_s_axis_tvalid) || cordic_s_axis_tready);

    wire fft_output_accept;
    wire cordic_output_accept;
    assign fft_output_accept    = fft_m_axis_tvalid && fft_m_axis_tready;
    assign cordic_output_accept = (state == ST_OUTPUT) && cordic_m_axis_tvalid;

    //-------------------------------------------------------------------------
    // BRAM_FreqDomain write decode
    //-------------------------------------------------------------------------
    // CORDIC outputs 8192 bins in natural order. Only bin 0..4095 is stored;
    // bins 4096..8191 are still consumed so that the FFT/CORDIC stream drains
    // completely and the next frame cannot see stale back-pressure.
    wire [CORDIC_OUTPUT_WIDTH-1:0] cordic_magnitude;
    assign cordic_magnitude = cordic_m_axis_tdata[CORDIC_OUTPUT_WIDTH-1:0];

    always @* begin
        freq_wr_en   = 1'b0;
        freq_wr_addr = {FREQ_ADDR_WIDTH{1'b0}};
        freq_wr_data = 32'd0;

        if (cordic_output_accept && (cordic_output_count < FREQ_DEPTH)) begin
            freq_wr_en   = 1'b1;
            freq_wr_addr = cordic_output_count[FREQ_ADDR_WIDTH-1:0];
            freq_wr_data = {{(32-CORDIC_OUTPUT_WIDTH){1'b0}}, cordic_magnitude};
        end
    end

    //-------------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------------
    always @(posedge calc_clk) begin
        if (rst) begin
            state                    <= ST_IDLE;
            sample_count             <= {ADDR_WIDTH{1'b0}};
            time_rd_addr             <= {ADDR_WIDTH{1'b0}};
            cordic_output_count      <= 13'd0;
            fft_config_tdata         <= FFT_FORWARD_CONFIG;
            fft_config_tvalid        <= 1'b0;
            fft_s_axis_tdata         <= {FFT_INPUT_TDATA_WIDTH{1'b0}};
            fft_s_axis_tvalid        <= 1'b0;
            fft_s_axis_tlast         <= 1'b0;
            cordic_s_axis_tdata      <= {CORDIC_INPUT_TDATA_WIDTH{1'b0}};
            cordic_s_axis_tvalid     <= 1'b0;
            freq_frame_done_toggle   <= 1'b0;
            freq_frame_done_pulse    <= 1'b0;
            frame_valid              <= 1'b0;
            busy                     <= 1'b0;
        end
        else begin
            freq_frame_done_pulse <= 1'b0;
            frame_valid            <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy                 <= 1'b0;
                    fft_config_tvalid    <= 1'b0;
                    fft_s_axis_tvalid    <= 1'b0;
                    cordic_s_axis_tvalid <= 1'b0;

                    if (new_frame_event) begin
                        busy              <= 1'b1;
                        fft_config_tdata <= FFT_FORWARD_CONFIG;
                        fft_config_tvalid <= 1'b1;
                        state            <= ST_CONFIG;
                    end
                end

                ST_CONFIG: begin
                    busy <= 1'b1;
                    // Configuration is held until an actual AXI handshake.
                    if (fft_config_tvalid && fft_config_tready) begin
                        fft_config_tvalid <= 1'b0;
                        sample_count      <= {ADDR_WIDTH{1'b0}};
                        time_rd_addr      <= {ADDR_WIDTH{1'b0}};
                        state             <= ST_READ_REQUEST;
                    end
                end

                ST_READ_REQUEST: begin
                    busy  <= 1'b1;
                    // time_rd_en and window_rom_en are high in this state.
                    // Both memories update their output registers at this edge.
                    state <= ST_PREPARE;
                end

                ST_PREPARE: begin
                    busy              <= 1'b1;
                    // Synchronous BRAM/ROM data are now aligned for the same
                    // sample index. Load and hold the complete AXI input word.
                    fft_s_axis_tdata  <= {16'd0, windowed_sample_s};
                    fft_s_axis_tlast  <= (sample_count == LAST_SAMPLE_ADDR);
                    fft_s_axis_tvalid <= 1'b1;
                    state             <= ST_SEND;
                end

                ST_SEND: begin
                    busy <= 1'b1;
                    // Do not change valid/data/tlast while FFT is not ready.
                    if (fft_s_axis_tvalid && fft_s_axis_tready) begin
                        fft_s_axis_tvalid <= 1'b0;

                        if (sample_count == LAST_SAMPLE_ADDR) begin
                            // The FFT must finish the frame before it produces
                            // output. Start counting CORDIC results from bin 0.
                            cordic_output_count <= 13'd0;
                            state               <= ST_OUTPUT;
                        end
                        else begin
                            sample_count <= sample_count + 1'b1;
                            time_rd_addr <= sample_count + 1'b1;
                            state        <= ST_READ_REQUEST;
                        end
                    end
                end

                ST_OUTPUT: begin
                    busy <= 1'b1;

                    // Consume an existing CORDIC input item if ready. If an FFT
                    // output is accepted in the same cycle, the second assignment
                    // below keeps valid asserted with the newly captured item.
                    if (cordic_s_axis_tvalid && cordic_s_axis_tready)
                        cordic_s_axis_tvalid <= 1'b0;

                    if (fft_output_accept) begin
                        cordic_s_axis_tdata  <= cordic_input_from_fft;
                        cordic_s_axis_tvalid <= 1'b1;
                    end

                    if (cordic_output_accept) begin
                        if (cordic_output_count == LAST_FFT_BIN) begin
                            // The final CORDIC output is accepted and, for the
                            // first 4096 outputs, written at this same edge.
                            freq_frame_done_toggle <= ~freq_frame_done_toggle;
                            freq_frame_done_pulse  <= 1'b1;
                            frame_valid            <= 1'b1;
                            busy                   <= 1'b0;
                            state                  <= ST_DONE;
                        end
                        else begin
                            cordic_output_count <= cordic_output_count + 1'b1;
                        end
                    end
                end

                ST_DONE: begin
                    // Keep a one-cycle terminal state so result pulses cannot
                    // be confused with a new frame event.
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule
