`timescale 1ns/1ps
// Whole-vector stable-time filter. Synchronizers are not a replacement for
// settling: a multi-switch transition is accepted only after STABLE_CYCLES.
module Switch_Filter #(
    parameter integer WIDTH=5,
    parameter integer STABLE_CYCLES=2_000_000
)(
    input wire clk, rst,
    input wire [WIDTH-1:0] async_in,
    output reg [WIDTH-1:0] stable_out,
    output reg ready
);
    localparam integer CW=(STABLE_CYCLES<2)?1:$clog2(STABLE_CYCLES);
    (* ASYNC_REG="TRUE" *) reg [WIDTH-1:0] meta, sync;
    reg [WIDTH-1:0] candidate;
    reg [CW-1:0] count;
    always @(posedge clk) begin
        if(rst) begin
            meta<=0; sync<=0; candidate<=0; stable_out<=0; count<=0; ready<=0;
        end else begin
            meta<=async_in; sync<=meta;
            if(sync!=candidate) begin candidate<=sync; count<=0; end
            else if(count==STABLE_CYCLES-1 || STABLE_CYCLES<=1) begin
                stable_out<=candidate; ready<=1;
            end else count<=count+1'b1;
        end
    end
endmodule
