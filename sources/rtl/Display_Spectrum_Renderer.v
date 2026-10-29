`timescale 1ns/1ps
// Three frequency-sorted component STEM plot, not decimation of FFT bins.
// Produces W logical positive-up levels; each peak maps to the nearest pixel.
// Peaks sharing a pixel use max amplitude and raise collision; out-of-range
// components are excluded and flagged, never silently folded onto an edge.
// Caller supplies detected components; raw noise/undetected tones are NOT shown.
module Display_Spectrum_Renderer #(parameter integer W=240,H=160)(
    input wire clk,rst,input wire in_valid,output wire in_ready,
    input wire signal_valid,input wire [1:0] component_count,
    input wire [95:0] frequencies_hz,magnitudes_raw,
    input wire [31:0] frequency_min,frequency_max,frame_id,
    output reg axis_valid,plot_valid,collision,out_of_range,
    output reg [31:0] scale_raw,frame_id_out,
    output reg pixel_valid,input wire pixel_ready,
    output reg [15:0] pixel_index,output reg [7:0] pixel_y,
    output reg done,output wire busy
);
    localparam IDLE=0,VALIDATE=1,AXIS=2,X_START=3,X_WAIT=4,Y_START=5,Y_WAIT=6,
        NEXT_SLOT=7,PREPARE=8,EMIT=9,WAIT_PIXEL=10;
    reg [3:0] state;
    reg [1:0] count,slot;
    reg source_valid,range_valid;
    reg [31:0] freq[0:2],mag[0:2],fmin,fmax;
    reg [2:0] used;
    reg [15:0] xpos[0:2],point;
    reg [7:0] ypos[0:2],level;
    wire div_ready,div_valid,div_zero;
    wire [47:0] q;
    wire [47:0] range_span={16'd0,fmax}-{16'd0,fmin};
    wire [47:0] nx=({16'd0,freq[slot]}-{16'd0,fmin})*(W-1)+(range_span>>1);
    wire [47:0] ny={16'd0,mag[slot]}*(H-1)+({16'd0,scale_raw}>>1);
    wire div_request=(state==X_START && used[slot]) || state==Y_START;
    integer i,j;
    Display_Unsigned_Divider #(.WIDTH(48)) u_div(
        .clk(clk),.rst(rst),.in_valid(div_request),.in_ready(div_ready),
        .numerator((state==X_START)?nx:ny),
        .denominator((state==X_START)?range_span:{16'd0,scale_raw}),
        .out_valid(div_valid),.out_ready(state==X_WAIT || state==Y_WAIT),
        .quotient(q),.remainder(),.divide_by_zero(div_zero));
    assign in_ready=!rst && state==IDLE && !pixel_valid;
    assign busy=(state!=IDLE) || pixel_valid;
    always @* begin
        level=0;
        for(j=0;j<3;j=j+1)
            if(used[j] && xpos[j]==point && ypos[j]>level) level=ypos[j];
    end
    // synthesis translate_off
    initial if(W<2 || W>65535 || H<2 || H>256) $fatal(1,"Invalid spectrum renderer parameters");
    // synthesis translate_on
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;count<=0;slot<=0;source_valid<=0;range_valid<=0;
            fmin<=0;fmax<=0;used<=0;point<=0;scale_raw<=0;frame_id_out<=0;
            axis_valid<=0;plot_valid<=0;collision<=0;out_of_range<=0;
            pixel_valid<=0;pixel_index<=0;pixel_y<=0;done<=0;
            for(i=0;i<3;i=i+1) begin freq[i]<=0;mag[i]<=0;xpos[i]<=0;ypos[i]<=0;end
        end else begin
            axis_valid<=0;done<=0;
            case(state)
                IDLE:if(in_valid && in_ready) begin
                    count<=component_count;source_valid<=signal_valid;
                    fmin<=frequency_min;fmax<=frequency_max;range_valid<=frequency_max>frequency_min;
                    frame_id_out<=frame_id;used<=0;scale_raw<=0;point<=0;slot<=0;
                    collision<=0;out_of_range<=frequency_max<=frequency_min;plot_valid<=0;
                    for(i=0;i<3;i=i+1) begin
                        freq[i]<=frequencies_hz[i*32+:32];mag[i]<=magnitudes_raw[i*32+:32];
                        xpos[i]<=0;ypos[i]<=0;
                    end
                    state<=VALIDATE;
                end
                VALIDATE: begin
                    if(source_valid && slot<count && mag[slot]!=0) begin
                        if(range_valid && freq[slot]>=fmin && freq[slot]<=fmax) begin
                            used[slot]<=1;
                            if(mag[slot]>scale_raw) scale_raw<=mag[slot];
                        end else out_of_range<=1;
                    end
                    if(slot==2) begin slot<=0;state<=AXIS;end else slot<=slot+1'b1;
                end
                AXIS:begin axis_valid<=1;plot_valid<=scale_raw!=0;state<=X_START;end
                X_START:if(!used[slot]) state<=NEXT_SLOT;else if(div_ready) state<=X_WAIT;
                X_WAIT:if(div_valid) begin
                    xpos[slot]<=(q>W-1)?W-1:q;state<=Y_START;
                    if(div_zero) out_of_range<=1;
                end
                Y_START:if(div_ready) state<=Y_WAIT;
                Y_WAIT:if(div_valid) begin ypos[slot]<=(q>H-1)?H-1:q;state<=NEXT_SLOT;end
                NEXT_SLOT:if(slot==2) state<=PREPARE;else begin slot<=slot+1'b1;state<=X_START;end
                PREPARE:begin
                    collision<=(used[0] && used[1] && xpos[0]==xpos[1]) ||
                        (used[0] && used[2] && xpos[0]==xpos[2]) ||
                        (used[1] && used[2] && xpos[1]==xpos[2]);
                    state<=EMIT;
                end
                EMIT:begin pixel_index<=point;pixel_y<=level;pixel_valid<=1;state<=WAIT_PIXEL;end
                WAIT_PIXEL:if(pixel_valid && pixel_ready) begin
                    pixel_valid<=0;
                    if(point==W-1) begin done<=1;state<=IDLE;end
                    else begin point<=point+1'b1;state<=EMIT;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
