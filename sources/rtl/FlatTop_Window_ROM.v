`timescale 1ns / 1ps

//==============================================================================
// FlatTop_Window_ROM
//------------------------------------------------------------------------------
// 8192 点平顶窗系数 ROM 的 RTL 封装。
//
// 实际存储体由 Vivado Block Memory Generator IP 完成，IP 名称固定为
// flat_top_window_rom。该 IP 配置为 Single Port ROM、8192 x 16 bit、
// COE 初始化、ENA 使能以及 1 个时钟周期的同步读延迟。
//
// data 是有符号 Q1.15 系数。FFT_Processor 与同步读时域 BRAM 同时发出
// en/address，下一拍同时得到采样值与窗系数。
//==============================================================================
module FlatTop_Window_ROM #(
    parameter integer ADDR_WIDTH = 13,
    parameter integer DATA_WIDTH = 16
)(
    input  wire                         clk,
    input  wire                         en,
    input  wire [ADDR_WIDTH-1:0]        addr,
    output wire signed [DATA_WIDTH-1:0] data
);

    wire [DATA_WIDTH-1:0] rom_data;

    flat_top_window_rom u_flat_top_window_rom (
        .clka (clk),
        .ena  (en),
        .addra(addr),
        .douta(rom_data)
    );

    assign data = $signed(rom_data);

endmodule
