`timescale 1ns/1ps
// Fractional raw-BRAM sampler: 16-tap, 64-phase windowed-sinc interpolation.
// Uses ONE time-shared 16x16 multiplier, replacing the old linear multiplier.
// Input Q12 sample address is rounded to the nearest 1/64 sample, with carry.
// No fundamental-only synthesis: every output uses 16 actual signed samples.
module Display_Bandlimited_Interpolator #(
    parameter integer FRAME_LENGTH=8192,ADDR_WIDTH=13
)(
    input wire clk,rst,in_valid,output wire in_ready,input wire [47:0] coordinate,
    output wire rd_en,output wire [ADDR_WIDTH-1:0] rd_addr,input wire signed [15:0] rd_data,
    output reg out_valid,input wire out_ready,output reg signed [15:0] sample,
    output reg edge_clamped,overflow
);
    localparam IDLE=0,REQ=1,READ=2,MULTIPLY=3,ACCUMULATE=4,FINISH=5,RESULT=6;
    reg [2:0] state;
    reg [3:0] tap;
    reg [5:0] phase;
    reg [35:0] base_index;
    reg signed [15:0] operand,weight;
    (* use_dsp="yes" *) reg signed [31:0] product;
    reg signed [35:0] accumulator;
    wire [6:0] rounded_phase={1'b0,coordinate[11:6]}+coordinate[5];
    wire signed [37:0] requested=$signed({2'b0,base_index})+$signed({34'd0,tap})-38'sd7;
    wire outside=requested<0 || requested>=FRAME_LENGTH;
    wire signed [15:0] coefficient;
    wire signed [36:0] rounded={accumulator[35],accumulator}+37'sd8192;
    wire signed [36:0] value=rounded>>>14;
    Display_Interpolation_ROM u_coeff(.clk(clk),.address({phase,tap}),.coefficient(coefficient));
    assign in_ready=!rst && state==IDLE && !out_valid;
    assign rd_en=state==REQ;
    assign rd_addr=requested<0?{ADDR_WIDTH{1'b0}}:
        (requested>=FRAME_LENGTH?FRAME_LENGTH-1:requested[ADDR_WIDTH-1:0]);
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;tap<=0;phase<=0;base_index<=0;operand<=0;weight<=0;product<=0;accumulator<=0;
            out_valid<=0;sample<=0;edge_clamped<=0;overflow<=0;
        end else case(state)
            IDLE:if(in_valid && in_ready)begin
                phase<=rounded_phase[5:0];base_index<=coordinate[47:12]+rounded_phase[6];
                tap<=0;accumulator<=0;edge_clamped<=0;overflow<=0;state<=REQ;
            end
            REQ:begin if(outside)edge_clamped<=1;state<=READ;end
            READ:begin operand<=rd_data;weight<=coefficient;state<=MULTIPLY;end
            MULTIPLY:begin product<=operand*weight;state<=ACCUMULATE;end
            ACCUMULATE:begin
                accumulator<=accumulator+product;
                if(tap==15)state<=FINISH;else begin tap<=tap+1'b1;state<=REQ;end
            end
            FINISH:begin
                if(value>32767)begin sample<=32767;overflow<=1;end
                else if(value< -32768)begin sample<=-32768;overflow<=1;end
                else sample<=value[15:0];
                state<=RESULT;
            end
            RESULT:begin
                out_valid<=1;
                if(out_valid && out_ready)begin out_valid<=0;state<=IDLE;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
