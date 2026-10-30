`timescale 1ns/1ps
// Display-only fundamental phase/period estimator. NEVER replaces plot samples.
// Two Hann-weighted half-frame projections isolate the selected fundamental.
// Their phase difference refines its coarse FFT bin. One time-shared multiplier,
// one quarter sine ROM, iterative vectoring CORDIC and serial divider.
// Full turn = 2^32; bin_q20 is FFT-bin units; sample coordinates are Q12.
// Upstream must freeze the BRAM until the complete display transaction finishes.
module Display_Fundamental_Aligner #(
    parameter integer FRAME_LENGTH=8192,ADDR_WIDTH=13
)(
    input wire clk,rst,in_valid,output wire in_ready,
    input wire [11:0] fundamental_bin,input wire [15:0] amax,
    output wire rd_en,output wire [ADDR_WIDTH-1:0] rd_addr,
    input wire signed [15:0] rd_data,
    output reg out_valid,input wire out_ready,output reg locked,
    output reg [31:0] bin_q20,period_q12,start_q12
);
    localparam integer L=$clog2(FRAME_LENGTH),HALF=FRAME_LENGTH/2;
    localparam IDLE=0,REQ=1,READ=2,WINDOW=3,SET_WIN=4,MUL_WAIT=5,MUL_USE=6,
        COS_REQ=7,COS_SET=8,SIN_REQ=9,SIN_SET=10,NEXT=11,
        CORD_INIT=12,CORD_RUN=13,CORD_SAVE=14,REFINE=15,CHECK=16,
        DIV_PERIOD=17,WAIT_PERIOD=18,DIV_START=19,WAIT_START=20,RESULT=21;
    reg [4:0] state,after_mul;
    reg [1:0] mul_kind;
    reg [ADDR_WIDTH-1:0] n;
    reg [11:0] coarse;
    reg [15:0] peak;
    reg [31:0] oscillator,phase_step,rom_phase;
    wire signed [15:0] trig;
    reg signed [15:0] sample;
    reg signed [23:0] weighted,mul_a;
    reg signed [16:0] mul_b;
    (* use_dsp="yes" *) reg signed [40:0] product;
    reg signed [55:0] x0,y0,x1,y1;
    reg signed [33:0] cx,cy;
    reg [31:0] z,phi0,phi1,origin;
    reg [4:0] iteration;
    reg second;
    wire signed [31:0] phase_delta=$signed(phi1-phi0);
    // Keep this arithmetic shift outside the unsigned modulo-phase subtraction.
    wire signed [31:0] half_delta=phase_delta>>>1;
    reg signed [32:0] refined;
    wire [55:0] ax0=x0[55]?-x0:x0,ay0=y0[55]?-y0:y0;
    wire [55:0] ax1=x1[55]?-x1:x1,ay1=y1[55]?-y1:y1;
    wire [55:0] threshold={40'd0,peak}<<23;
    wire dv_ready,dv_valid,dv_zero;
    wire [63:0] quotient;
    wire [31:0] negative_origin=-origin;
    Display_Sine_ROM u_rom(.clk(clk),.phase(rom_phase),.value(trig));
    Display_Unsigned_Divider #(.WIDTH(64)) u_div(
        .clk(clk),.rst(rst),.in_valid(state==DIV_PERIOD || state==DIV_START),
        .in_ready(dv_ready),
        .numerator(state==DIV_PERIOD?(64'd1<<(L+32)):({32'd0,negative_origin}<<12)),
        .denominator(state==DIV_PERIOD?{32'd0,bin_q20}:{32'd0,phase_step}),
        .out_valid(dv_valid),.out_ready(state==WAIT_PERIOD || state==WAIT_START),
        .quotient(quotient),.remainder(),.divide_by_zero(dv_zero));
    assign in_ready=!rst && state==IDLE && !out_valid;
    assign rd_en=state==REQ;
    assign rd_addr=n;
    function [31:0] angle;
        input [4:0] i;
        begin case(i)
            0:angle=32'd536870912;
            1:angle=32'd316933406;
            2:angle=32'd167458907;
            3:angle=32'd85004756;
            4:angle=32'd42667331;
            5:angle=32'd21354465;
            6:angle=32'd10679838;
            7:angle=32'd5340245;
            8:angle=32'd2670163;
            9:angle=32'd1335087;
            10:angle=32'd667544;
            11:angle=32'd333772;
            12:angle=32'd166886;
            13:angle=32'd83443;
            14:angle=32'd41722;
            15:angle=32'd20861;
            16:angle=32'd10430;
            17:angle=32'd5215;
            18:angle=32'd2608;
            19:angle=32'd1304;
            20:angle=32'd652;
            21:angle=32'd326;
            22:angle=32'd163;
            23:angle=32'd81;
            24:angle=32'd41;
            25:angle=32'd20;
            26:angle=32'd10;
            27:angle=32'd5;
            28:angle=32'd3;
            29:angle=32'd1;
            default:angle=0;
        endcase end
    endfunction
    // synthesis translate_off
    initial if(FRAME_LENGTH!=(1<<L) || L<6 || L>13)
        $fatal(1,"Alignment requires a power-of-two frame, 64..8192");
    // synthesis translate_on
    always @(posedge clk) begin
        // A single explicit multiplication is shared by window/I/Q operations.
        product<=mul_a*mul_b;
        if(rst) begin
            state<=IDLE;after_mul<=IDLE;mul_kind<=0;n<=0;coarse<=0;peak<=0;
            oscillator<=0;phase_step<=0;rom_phase<=0;sample<=0;weighted<=0;
            mul_a<=0;mul_b<=0;x0<=0;y0<=0;x1<=0;y1<=0;
            cx<=0;cy<=0;z<=0;phi0<=0;phi1<=0;origin<=0;
            iteration<=0;second<=0;refined<=0;
            out_valid<=0;locked<=0;bin_q20<=0;period_q12<=0;start_q12<=0;
        end else case(state)
            IDLE:if(in_valid && in_ready) begin
                coarse<=fundamental_bin;peak<=amax;
                bin_q20<={fundamental_bin,20'd0};locked<=0;
                period_q12<=0;start_q12<=0;out_valid<=0;
                n<=0;oscillator<=0;phase_step<={20'd0,fundamental_bin}<<(32-L);
                x0<=0;y0<=0;x1<=0;y1<=0;
                if(fundamental_bin==0 || fundamental_bin>=HALF || amax==0) state<=RESULT;
                else state<=REQ;
            end
            REQ:state<=READ;
            READ:begin
                sample<=rd_data;
                // cos(window phase) = sin(window phase + quarter turn).
                rom_phase<=({{(32-ADDR_WIDTH){1'b0}},n}<<(33-L))+32'h40000000;
                state<=WINDOW;
            end
            WINDOW:state<=SET_WIN;
            SET_WIN:begin
                mul_a<=sample;mul_b<=$signed(17'sd32767-$signed(trig))>>>1;
                mul_kind<=0;after_mul<=COS_REQ;state<=MUL_WAIT;
            end
            MUL_WAIT:state<=MUL_USE;
            MUL_USE:begin
                case(mul_kind)
                    0:weighted<=product>>>8;
                    1:if(n<HALF)x0<=x0+product;else x1<=x1+product;
                    2:if(n<HALF)y0<=y0+product;else y1<=y1+product;
                endcase
                state<=after_mul;
            end
            COS_REQ:begin rom_phase<=oscillator+32'h40000000;state<=COS_SET;end
            COS_SET:state<=SIN_REQ;
            SIN_REQ:begin
                mul_a<=weighted;mul_b<=trig;mul_kind<=1;after_mul<=SIN_SET;
                rom_phase<=oscillator;state<=MUL_WAIT;
            end
            SIN_SET:begin
                mul_a<=weighted;mul_b<=trig;mul_kind<=2;after_mul<=NEXT;state<=MUL_WAIT;
            end
            NEXT:if(n==FRAME_LENGTH-1) begin second<=0;state<=CORD_INIT;end
                else begin n<=n+1'b1;oscillator<=oscillator+phase_step;state<=REQ;end
            CORD_INIT:begin
                // atan2(sum(x*cos),sum(x*sin)) gives sine's initial phase.
                if(second?y1[55]:y0[55]) begin
                    cx<=-(second?y1>>>18:y0>>>18);
                    cy<=-(second?x1>>>18:x0>>>18);z<=32'h80000000;
                end else begin
                    cx<=second?y1>>>18:y0>>>18;
                    cy<=second?x1>>>18:x0>>>18;z<=0;
                end
                iteration<=0;state<=CORD_RUN;
            end
            CORD_RUN:begin
                if(cy>0) begin cx<=cx+(cy>>>iteration);cy<=cy-(cx>>>iteration);z<=z+angle(iteration);end
                else if(cy<0) begin cx<=cx-(cy>>>iteration);cy<=cy+(cx>>>iteration);z<=z-angle(iteration);end
                if(iteration==29)state<=CORD_SAVE;else iteration<=iteration+1'b1;
            end
            CORD_SAVE:if(!second)begin phi0<=z;second<=1;state<=CORD_INIT;end
                else begin phi1<=z;state<=REFINE;end
            REFINE:begin
                // Window centers are N/2 samples apart: delta bins = 2*delta turns.
                refined<=$signed({1'b0,coarse,20'd0})+($signed(phase_delta)>>>11);
                origin<=phi0-half_delta;state<=CHECK;
            end
            CHECK:begin
                if(refined<=0 || refined>=((64'd1<<(L-1))<<20) ||
                    phase_delta>32'sh60000000 || phase_delta< -32'sh60000000 ||
                    (ax0<threshold && ay0<threshold) || (ax1<threshold && ay1<threshold)) begin
                    // Low-confidence phase is not used to invent a trigger.
                    state<=RESULT;
                end else begin
                    bin_q20<=refined[31:0];
                    if(L>=12)phase_step<=refined[31:0]>>(L-12);
                    else phase_step<=refined[31:0]<<(12-L);
                    locked<=1;state<=DIV_PERIOD;
                end
            end
            DIV_PERIOD:if(dv_ready)state<=WAIT_PERIOD;
            WAIT_PERIOD:if(dv_valid)begin
                period_q12<=quotient[31:0];
                if(dv_zero)begin locked<=0;state<=RESULT;end else state<=DIV_START;
            end
            DIV_START:if(dv_ready)state<=WAIT_START;
            WAIT_START:if(dv_valid)begin
                start_q12<=quotient[31:0];if(dv_zero)locked<=0;state<=RESULT;
            end
            RESULT:begin out_valid<=1;if(out_valid && out_ready)begin out_valid<=0;state<=IDLE;end end
            default:state<=IDLE;
        endcase
    end
endmodule
