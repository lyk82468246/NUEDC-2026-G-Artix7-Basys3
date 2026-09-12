`timescale 1ns / 1ps

//==============================================================================
// BRAM_TimeDomain
//------------------------------------------------------------------------------
// 8192 x 16-bit 多读口、双时钟时域缓存。
//
// 写端口在 adc_clk 域，三个读端口在 calc_clk 域。为了让时域统计、FFT 和
// UART 波形下发可以在同一帧上独立工作，这里复制三个 BRAM 读副本；每个
// 副本都是“一写一读”的同步 RAM。Artix-7 的 BRAM 资源足以容纳该复制，
// 代价是时域缓存约使用原来的三倍 BRAM。
//
// 读端口为同步读：rd_en 在某个 calc_clk 上升沿被采样，rd_data 在该沿之后
// 更新。因此 Time_Domain_Calc 使用 READ_REQUEST -> PROCESS 两状态配合。
// rd1：Time_Domain_Calc；rd2：FFT_Processor；rd3：HMI_UART_Ctrl。
//==============================================================================
module BRAM_TimeDomain #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 13,
    parameter integer DEPTH      = 8192
)(
    input  wire                           wr_clk,
    input  wire                           wr_en,
    input  wire [ADDR_WIDTH-1:0]          wr_addr,
    input  wire signed [DATA_WIDTH-1:0]   wr_data,

    input  wire                           rd_clk,
    input  wire                           rd_en,
    input  wire [ADDR_WIDTH-1:0]          rd_addr,
    output reg  signed [DATA_WIDTH-1:0]   rd_data,

    input  wire                           rd2_clk,
    input  wire                           rd2_en,
    input  wire [ADDR_WIDTH-1:0]          rd2_addr,
    output reg  signed [DATA_WIDTH-1:0]   rd2_data,

    input  wire                           rd3_clk,
    input  wire                           rd3_en,
    input  wire [ADDR_WIDTH-1:0]          rd3_addr,
    output reg  signed [DATA_WIDTH-1:0]   rd3_data
);

    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] mem_calc [0:DEPTH-1];
    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] mem_fft  [0:DEPTH-1];
    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] mem_hmi  [0:DEPTH-1];

    always @(posedge wr_clk) begin
        if (wr_en) begin
            mem_calc[wr_addr] <= wr_data;
            mem_fft [wr_addr] <= wr_data;
            mem_hmi [wr_addr] <= wr_data;
        end
    end

    always @(posedge rd_clk) begin
        if (rd_en)
            rd_data <= mem_calc[rd_addr];
    end

    always @(posedge rd2_clk) begin
        if (rd2_en)
            rd2_data <= mem_fft[rd2_addr];
    end

    always @(posedge rd3_clk) begin
        if (rd3_en)
            rd3_data <= mem_hmi[rd3_addr];
    end

endmodule
