`timescale 1ns/1ps
// Packed bank: {enabled, vpp_gain[31:0], rms_gain[31:0], fft_gain[31:0]}.
// Invalid/ambiguous records return valid=0/source=0 or 3; caller uses defaults.
// Equality includes saved_epoch, as the on-flash records must be identical.
module Calibration_Record_Select(
    input wire clk,por,in_valid,output wire in_ready,
    input wire a_valid,b_valid,input wire [96:0] a_bank,b_bank,
    input wire [31:0] a_sequence,b_sequence,a_epoch,b_epoch,
    output reg out_valid,input wire out_ready,
    output reg record_valid,output reg [1:0] source,
    output reg [96:0] bank,output reg [31:0] record_sequence,saved_epoch
);
    wire [31:0] delta=a_sequence-b_sequence;
    wire conflict=a_valid && b_valid &&
        ((delta==0 && (a_bank!=b_bank || a_epoch!=b_epoch)) || delta==32'h80000000);
    wire use_a=a_valid && (!b_valid || delta==0 || !delta[31]);
    assign in_ready=!por && !out_valid;
    always @(posedge clk)begin
        if(por)begin out_valid<=0;record_valid<=0;source<=0;bank<=0;record_sequence<=0;saved_epoch<=0;end
        else begin
            if(out_valid && out_ready)out_valid<=0;
            if(in_valid && in_ready)begin
                out_valid<=1;record_valid<=0;source<=0;bank<=0;record_sequence<=0;saved_epoch<=0;
                if(conflict)source<=3;
                else if(a_valid || b_valid)begin
                    record_valid<=1;source<=use_a?1:2;bank<=use_a?a_bank:b_bank;
                    record_sequence<=use_a?a_sequence:b_sequence;saved_epoch<=use_a?a_epoch:b_epoch;
                end
            end
        end
    end
endmodule
