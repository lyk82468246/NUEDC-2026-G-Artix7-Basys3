`timescale 1ns/1ps
// Iterative unsigned restoring divider. No combinational / or vendor IP.
// One request outstanding; both request and result use valid/ready handshakes.
// Divide-by-zero completes with all-ones quotient and an explicit error flag.
module Display_Unsigned_Divider #(parameter integer WIDTH=48)(
    input wire clk,rst,input wire in_valid,output wire in_ready,
    input wire [WIDTH-1:0] numerator,denominator,
    output reg out_valid,input wire out_ready,
    output reg [WIDTH-1:0] quotient,remainder,
    output reg divide_by_zero
);
    localparam integer CW=$clog2(WIDTH+1);
    reg running;
    reg [CW-1:0] remaining;
    reg [WIDTH-1:0] dividend,divisor,q;
    reg [WIDTH:0] r;
    wire [WIDTH:0] trial={r[WIDTH-1:0],dividend[WIDTH-1]};
    // One subtractor supplies both the difference and unsigned borrow; avoid
    // a separate wide comparator in front of a second wide carry chain.
    wire [WIDTH+1:0] difference={1'b0,trial}-{2'b0,divisor};
    wire subtract=!difference[WIDTH+1];
    wire [WIDTH:0] next_r=subtract?difference[WIDTH:0]:trial;
    wire [WIDTH-1:0] next_q={q[WIDTH-2:0],subtract};
    assign in_ready=!rst && !running && !out_valid;
    always @(posedge clk) begin
        if(rst) begin
            running<=0;remaining<=0;dividend<=0;divisor<=0;q<=0;r<=0;
            out_valid<=0;quotient<=0;remainder<=0;divide_by_zero<=0;
        end else begin
            if(out_valid && out_ready) out_valid<=0;
            if(in_valid && in_ready) begin
                divide_by_zero<=(denominator==0);
                if(denominator==0) begin
                    quotient<={WIDTH{1'b1}};remainder<=numerator;out_valid<=1;
                end else begin
                    dividend<=numerator;divisor<=denominator;q<=0;r<=0;
                    remaining<=WIDTH;running<=1;
                end
            end else if(running) begin
                dividend<={dividend[WIDTH-2:0],1'b0};q<=next_q;r<=next_r;
                remaining<=remaining-1'b1;
                if(remaining==1) begin
                    running<=0;quotient<=next_q;remainder<=next_r[WIDTH-1:0];out_valid<=1;
                end
            end
        end
    end
endmodule
