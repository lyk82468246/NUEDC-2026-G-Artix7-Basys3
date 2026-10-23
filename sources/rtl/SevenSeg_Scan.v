`timescale 1ns/1ps
// Basys 3: seg[0]=a, an[0]=rightmost; all segment/digit enables active LOW.
// No derived clock: SCAN_CYCLES clocks per digit, with one blank cycle on
// transitions. Values/validity/decimal points are committed together at a scan
// boundary. >9999 shows OFLO, invalid shows ----, never silently truncates.
module SevenSeg_Scan #(
    parameter integer SCAN_CYCLES=25_000
)(
    input wire clk, rst,
    input wire [31:0] value,
    input wire valid,
    input wire [3:0] decimal_points,
    output reg [6:0] seg,
    output reg [3:0] an,
    output reg dp
);
    localparam integer CW=(SCAN_CYCLES<2)?1:$clog2(SCAN_CYCLES);
    reg [CW-1:0] count;
    reg [1:0] digit;
    wire [39:0] bcd;
    wire converting, converted;
    wire start_conversion=!converting && !converted;
    reg input_valid, input_overflow;
    reg [3:0] input_points;
    reg [15:0] pending_bcd, active_bcd;
    reg pending_valid, pending_overflow, active_valid, active_overflow;
    reg [3:0] pending_points, active_points;
    BIN2BCD u_bcd(.clk(clk),.rst(rst),.start(start_conversion),.binary_in(value),
        .bcd_out(bcd),.busy(converting),.done(converted));
    function [6:0] segments;
        input [3:0] n;
        begin
            case(n)
                0:segments=7'b1000000; 1:segments=7'b1111001;
                2:segments=7'b0100100; 3:segments=7'b0110000;
                4:segments=7'b0011001; 5:segments=7'b0010010;
                6:segments=7'b0000010; 7:segments=7'b1111000;
                8:segments=7'b0000000; 9:segments=7'b0010000;
                default:segments=7'b0111111;
            endcase
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            count<=0; digit<=0; input_valid<=0; input_overflow<=0; input_points<=0;
            pending_bcd<=0; active_bcd<=0; pending_valid<=0; active_valid<=0;
            pending_overflow<=0; active_overflow<=0; pending_points<=0; active_points<=0;
        end else begin
            if(start_conversion) begin
                input_valid<=valid; input_overflow<=(value>9999); input_points<=decimal_points;
            end
            if(converted) begin
                pending_bcd<=bcd[15:0]; pending_valid<=input_valid;
                pending_overflow<=input_overflow; pending_points<=input_points;
            end
            if(count==SCAN_CYCLES-1) begin
                count<=0; digit<=digit+1'b1;
                if(digit==3) begin
                    active_bcd<=pending_bcd; active_valid<=pending_valid;
                    active_overflow<=pending_overflow; active_points<=pending_points;
                end
            end else count<=count+1'b1;
        end
    end
    always @* begin
        an=4'b1111; dp=1; seg=7'b1111111;
        if(count!=0) begin
            an=~(4'b0001<<digit);
            if(!active_valid) seg=7'b0111111;
            else if(active_overflow) begin
                case(digit) // left-to-right O F L O
                    3,0:seg=7'b1000000;
                    2:seg=7'b0001110;
                    default:seg=7'b1000111;
                endcase
            end else begin
                seg=segments(active_bcd[digit*4 +: 4]); dp=~active_points[digit];
            end
        end
    end
endmodule
