`timescale 1ns/1ps
// Layout-independent plot stream. Caller MUST hold this frame's BRAM frozen
// from the start handshake through done, including downstream backpressure.
// Synchronous BRAM: rd_en at edge E -> rd_data consumed at edge E+1.
// First scan computes Amax=max(abs(samples)); then fractional coordinates use
// p*C*N/((W-1)*bin), including the repeated endpoint at C estimated periods.
// bin is still a 500-Hz-grid estimate: this fixes integer-span truncation, NOT
// off-grid frequency estimation or composite-waveform phase synchronization.
// Y is a LOGICAL positive-up level; the final screen adapter chooses inversion.
module Display_Wave_Renderer #(
    parameter integer FRAME_LENGTH=8192,ADDR_WIDTH=13,W=240,H=160,F=12
)(
    input wire clk,rst,input wire in_valid,output wire in_ready,
    input wire signal_valid,three_cycles,input wire [11:0] fundamental_bin,
    input wire [31:0] frame_id,
    output wire rd_en,output wire [ADDR_WIDTH-1:0] rd_addr,
    input wire signed [15:0] rd_data,
    output reg axis_valid,output reg [15:0] amax_raw,
    output reg plot_valid,window_clamped,
    output reg pixel_valid,input wire pixel_ready,
    output reg [15:0] pixel_index,output reg [7:0] pixel_y,
    output reg [31:0] frame_id_out,output reg done,output wire busy
);
    localparam IDLE=0,SCAN_REQ=1,SCAN_READ=2,ADDR_START=3,ADDR_WAIT=4,
        READ0_REQ=5,READ0=6,READ1_REQ=7,READ1=8,INTERPOLATE=9,
        Y_START=10,Y_WAIT=11,EMIT=12,WAIT_PIXEL=13;
    localparam integer MID=H/2,YSPAN=(H-1)/2;
    localparam [ADDR_WIDTH-1:0] LAST=FRAME_LENGTH-1;
    localparam [47:0] MAXQ=(FRAME_LENGTH-1)*(48'd1<<F);
    reg [3:0] state;
    reg [ADDR_WIDTH-1:0] scan_addr;
    reg [11:0] bin;
    reg [1:0] cycles;
    reg [15:0] point;
    reg [47:0] coord;
    reg signed [15:0] sample0,sample1,interpolated_sample;
    reg [7:0] pending_y;
    wire [ADDR_WIDTH-1:0] address0=coord[F+:ADDR_WIDTH];
    wire [ADDR_WIDTH-1:0] address1=(address0==LAST)?LAST:address0+1'b1;
    wire [16:0] abs_read=rd_data[15]?-$signed({rd_data[15],rd_data}):{1'b0,rd_data};
    wire [15:0] max_candidate=(abs_read>{1'b0,amax_raw})?abs_read[15:0]:amax_raw;
    wire signed [16:0] delta=$signed({sample1[15],sample1})-$signed({sample0[15],sample0});
    wire signed [47:0] delta_q=delta*$signed({1'b0,coord[F-1:0]});
    wire signed [47:0] base_q=$signed({{32{sample0[15]}},sample0})<<<F;
    wire signed [47:0] interpolated_q=base_q+delta_q;
    wire [16:0] abs_sample=interpolated_sample[15]?
        -$signed({interpolated_sample[15],interpolated_sample}):{1'b0,interpolated_sample};
    wire div_ready,div_valid,div_zero;
    wire div_request=(state==ADDR_START || (state==Y_START && amax_raw!=0));
    wire [47:0] address_numerator=({32'd0,point}*FRAME_LENGTH*cycles)<<F;
    wire [47:0] address_denominator=(W-1)*{36'd0,bin};
    wire [47:0] y_numerator=({31'd0,abs_sample}*YSPAN)+({32'd0,amax_raw}>>1);
    wire [47:0] quotient;
    Display_Unsigned_Divider #(.WIDTH(48)) u_div(
        .clk(clk),.rst(rst),.in_valid(div_request),.in_ready(div_ready),
        .numerator((state==ADDR_START)?address_numerator:y_numerator),
        .denominator((state==ADDR_START)?address_denominator:{32'd0,amax_raw}),
        .out_valid(div_valid),.out_ready(state==ADDR_WAIT || state==Y_WAIT),
        .quotient(quotient),.remainder(),.divide_by_zero(div_zero));
    assign in_ready=!rst && state==IDLE && !pixel_valid;
    assign busy=(state!=IDLE) || pixel_valid;
    assign rd_en=(state==SCAN_REQ || state==READ0_REQ || state==READ1_REQ);
    assign rd_addr=(state==SCAN_REQ)?scan_addr:((state==READ1_REQ)?address1:address0);
    // synthesis translate_off
    initial if(W<2 || W>65535 || H<3 || H>256 || F<1 || F>16 || FRAME_LENGTH<2 ||
               FRAME_LENGTH>(1<<ADDR_WIDTH)) $fatal(1,"Invalid wave renderer parameters");
    // synthesis translate_on
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;scan_addr<=0;bin<=0;cycles<=1;point<=0;coord<=0;
            sample0<=0;sample1<=0;interpolated_sample<=0;pending_y<=MID;
            axis_valid<=0;amax_raw<=0;plot_valid<=0;window_clamped<=0;
            pixel_valid<=0;pixel_index<=0;pixel_y<=0;frame_id_out<=0;done<=0;
        end else begin
            axis_valid<=0;done<=0;
            case(state)
                IDLE: if(in_valid && in_ready) begin
                    frame_id_out<=frame_id;bin<=fundamental_bin;cycles<=three_cycles?3:1;
                    point<=0;scan_addr<=0;amax_raw<=0;window_clamped<=0;pending_y<=MID;
                    plot_valid<=signal_valid && fundamental_bin!=0;
                    if(signal_valid && fundamental_bin!=0) state<=SCAN_REQ;
                    else begin axis_valid<=1;state<=EMIT;end
                end
                SCAN_REQ:state<=SCAN_READ;
                SCAN_READ: begin
                    amax_raw<=max_candidate;
                    if(scan_addr==LAST) begin
                        axis_valid<=1;plot_valid<=max_candidate!=0;state<=ADDR_START;
                    end else begin scan_addr<=scan_addr+1'b1;state<=SCAN_REQ;end
                end
                ADDR_START:if(div_ready) state<=ADDR_WAIT;
                ADDR_WAIT:if(div_valid) begin
                    if(quotient>MAXQ || div_zero) begin coord<=MAXQ;window_clamped<=1;end
                    else coord<=quotient;
                    state<=READ0_REQ;
                end
                READ0_REQ:state<=READ0;
                READ0:begin sample0<=rd_data;state<=READ1_REQ;end
                READ1_REQ:state<=READ1;
                READ1:begin sample1<=rd_data;state<=INTERPOLATE;end
                INTERPOLATE:begin interpolated_sample<=interpolated_q>>>F;state<=Y_START;end
                Y_START:if(amax_raw==0) begin pending_y<=MID;state<=EMIT;end
                        else if(div_ready) state<=Y_WAIT;
                Y_WAIT:if(div_valid) begin
                    if(div_zero) begin pending_y<=MID;plot_valid<=0;end
                    else if(interpolated_sample[15])
                        pending_y<=MID-((quotient>YSPAN)?YSPAN:quotient);
                    else pending_y<=MID+((quotient>YSPAN)?YSPAN:quotient);
                    state<=EMIT;
                end
                EMIT:begin pixel_index<=point;pixel_y<=pending_y;pixel_valid<=1;state<=WAIT_PIXEL;end
                WAIT_PIXEL:if(pixel_valid && pixel_ready) begin
                    pixel_valid<=0;
                    if(point==W-1) begin done<=1;state<=IDLE;end
                    else begin point<=point+1'b1;state<=plot_valid?ADDR_START:EMIT;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
