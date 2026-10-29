`timescale 1ns/1ps
// Format unsigned reference microvolts as decimal millivolts with ONE decimal:
// 123456uV -> ASCII "123.5". Half-up at 50uV; 33-bit addition prevents overflow.
// Invalid voltage -> "--", not misleading "0.0". No units/widget names/UART
// terminator here: those belong to the final screen protocol adapter.
module Display_mV_Formatter(
    input wire clk,rst,input wire in_valid,output wire in_ready,
    input wire voltage_valid,input wire [31:0] microvolts,
    output reg byte_valid,input wire byte_ready,
    output reg [7:0] byte_data,output reg byte_last,output reg done
);
    localparam IDLE=0,DIV_START=1,DIV_WAIT=2,BCD_START=3,BCD_WAIT=4,EMIT=5,WAIT_BYTE=6;
    reg [2:0] state;
    reg invalid,invalid_index;
    reg [31:0] uv,tenths_mv;
    reg [3:0] position;
    reg [1:0] phase; // integer digits, decimal point, fractional digit
    wire div_ready,div_valid;
    wire [32:0] q;
    wire [39:0] bcd;
    wire bcd_done;
    Display_Unsigned_Divider #(.WIDTH(33)) u_div(.clk(clk),.rst(rst),
        .in_valid(state==DIV_START),.in_ready(div_ready),
        .numerator({1'b0,uv}+33'd50),.denominator(33'd100),
        .out_valid(div_valid),.out_ready(state==DIV_WAIT),.quotient(q),.remainder(),.divide_by_zero());
    BIN2BCD #(.INPUT_WIDTH(32),.DIGITS(10)) u_bcd(.clk(clk),.rst(rst),
        .start(state==BCD_START),.binary_in(tenths_mv),.bcd_out(bcd),.busy(),.done(bcd_done));
    function [3:0] highest_integer_digit;
        input [39:0] digits;
        integer k;
        begin
            highest_integer_digit=1;
            for(k=1;k<10;k=k+1) if(digits[k*4+:4]!=0) highest_integer_digit=k;
        end
    endfunction
    assign in_ready=!rst && state==IDLE && !byte_valid;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;invalid<=0;invalid_index<=0;uv<=0;tenths_mv<=0;position<=1;phase<=0;
            byte_valid<=0;byte_data<=0;byte_last<=0;done<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(in_valid && in_ready) begin
                    uv<=microvolts;invalid<=!voltage_valid;invalid_index<=0;phase<=0;
                    state<=voltage_valid?DIV_START:EMIT;
                end
                DIV_START:if(div_ready) state<=DIV_WAIT;
                DIV_WAIT:if(div_valid) begin tenths_mv<=q[31:0];state<=BCD_START;end
                BCD_START:state<=BCD_WAIT;
                BCD_WAIT:if(bcd_done) begin position<=highest_integer_digit(bcd);state<=EMIT;end
                EMIT:begin
                    byte_data<=invalid?8'd45:((phase==1)?8'd46:
                        (8'd48+((phase==2)?bcd[3:0]:bcd[position*4+:4])));
                    byte_last<=invalid?invalid_index:(phase==2);
                    byte_valid<=1;state<=WAIT_BYTE;
                end
                WAIT_BYTE:if(byte_valid && byte_ready) begin
                    byte_valid<=0;
                    if(byte_last) begin done<=1;state<=IDLE;end
                    else begin
                        if(invalid) invalid_index<=1;
                        else if(phase==0) begin
                            if(position==1) phase<=1;else position<=position-1'b1;
                        end else phase<=2;
                        state<=EMIT;
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
