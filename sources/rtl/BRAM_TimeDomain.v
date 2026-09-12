`timescale 1ns / 1ps

//==============================================================================
// BRAM_TimeDomain
//------------------------------------------------------------------------------
// 8192 x 16-bit 真双口、双时钟时域缓存。
//
// 写端口在 adc_clk 域，读端口在 calc_clk 域。两个端口不共享地址寄存器，
// 适合 AFE_Capture 写入、Time_Domain_Calc 遍历读取的结构。
//
// 读端口为同步读：rd_en 在某个 calc_clk 上升沿被采样，rd_data 在该沿之后
// 更新。因此 Time_Domain_Calc 使用 READ_REQUEST -> PROCESS 两状态配合。
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
    output reg  signed [DATA_WIDTH-1:0]   rd_data
);

    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
