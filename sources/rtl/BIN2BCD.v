`timescale 1ns / 1ps

//==============================================================================
// BIN2BCD
//------------------------------------------------------------------------------
// 通用 Shift-and-Add-3（Double Dabble）二进制转 BCD 模块。
//
// 每个输入 bit 使用一个时钟周期，避免在 HMI 数据路径中推导大组合除法器。
// start 只有在 busy=0 时被接受；转换完成时 done 拉高一个时钟周期。
// bcd_out 的低 4 bit 是个位，随后依次为十位、百位……
//==============================================================================
module BIN2BCD #(
    parameter integer INPUT_WIDTH = 32,
    parameter integer DIGITS      = 10
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         start,
    input  wire [INPUT_WIDTH-1:0]       binary_in,
    output reg  [DIGITS*4-1:0]          bcd_out,
    output reg                          busy,
    output reg                          done
);

    localparam integer WORK_WIDTH = INPUT_WIDTH + DIGITS * 4;

    localparam ST_IDLE = 1'b0;
    localparam ST_RUN  = 1'b1;

    reg state;
    reg [WORK_WIDTH-1:0] work_reg;
    reg [WORK_WIDTH-1:0] work_adjusted;
    reg [WORK_WIDTH-1:0] work_shifted;
    reg [15:0] bit_count;
    integer i;

    // Add 3 to every BCD digit >= 5, then shift the combined register left.
    // The variable part-select is elaborated with constant digit positions.
    always @* begin
        work_adjusted = work_reg;
        for (i = 0; i < DIGITS; i = i + 1) begin
            if (work_adjusted[INPUT_WIDTH + i*4 +: 4] >= 4'd5)
                work_adjusted[INPUT_WIDTH + i*4 +: 4] =
                    work_adjusted[INPUT_WIDTH + i*4 +: 4] + 4'd3;
        end
        work_shifted = work_adjusted << 1;
    end

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_IDLE;
            work_reg  <= {WORK_WIDTH{1'b0}};
            bcd_out   <= {(DIGITS*4){1'b0}};
            bit_count <= 16'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end
        else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        work_reg  <= {{(DIGITS*4){1'b0}}, binary_in};
                        bit_count <= 16'd0;
                        busy      <= 1'b1;
                        state     <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    busy     <= 1'b1;
                    work_reg <= work_shifted;

                    if (bit_count == INPUT_WIDTH-1) begin
                        bcd_out <= work_shifted[WORK_WIDTH-1:INPUT_WIDTH];
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        state   <= ST_IDLE;
                    end
                    else begin
                        bit_count <= bit_count + 1'b1;
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
