`timescale 1ns / 1ps

//==============================================================================
// BRAM_FreqDomain
//------------------------------------------------------------------------------
// 4096 x 32-bit 频域幅值缓存。
//
// FFT_Processor 写入地址 0..4095 的正频率幅值，Peak_Search 在 FFT 完成
// 标志到达后使用同步读口顺序遍历。写、读共用 calc_clk，但保留独立的
// enable/address/data 信号，便于以后替换成 Block Memory Generator 双口 IP。
//==============================================================================
module BRAM_FreqDomain #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 12,
    parameter integer DEPTH      = 4096
)(
    input  wire                         clk,
    input  wire                         wr_en,
    input  wire [ADDR_WIDTH-1:0]        wr_addr,
    input  wire [DATA_WIDTH-1:0]        wr_data,
    input  wire                         rd_en,
    input  wire [ADDR_WIDTH-1:0]        rd_addr,
    output reg  [DATA_WIDTH-1:0]        rd_data
);

    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
