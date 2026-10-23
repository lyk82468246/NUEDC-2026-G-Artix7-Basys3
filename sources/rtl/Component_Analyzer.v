`timescale 1ns/1ps
// Three repeated BRAM scans with non-maximum suppression of flat-top mainlobes.
// Outputs are an atomic frequency-sorted snapshot, not the three largest bins.
// All magnitudes are RAW. Harmonic checks tolerate bin quantization increasing
// with order; they do not use exact integer GCD. Detection floor is configurable,
// not a guarantee of detecting an arbitrarily weak fundamental under noise.
module Component_Analyzer #(
    parameter integer EXCLUDE_BINS=6,
    parameter integer RELATIVE_FLOOR_SHIFT=8,
    parameter [31:0] ABSOLUTE_FLOOR=32'd64
)(
    input wire clk, rst,
    input wire frame_done_toggle,
    input wire [1:0] mode,
    output reg [11:0] rd_addr,
    output wire rd_en,
    input wire [31:0] rd_data,
    output reg [1:0] component_count,
    output reg [35:0] component_bins,
    output reg [95:0] component_magnitudes,
    output reg [11:0] fundamental_bin,
    output reg [31:0] fundamental_hz, fundamental_magnitude,
    output reg harmonics_consistent,
    output reg result_valid,
    output wire busy
);
    localparam [3:0] IDLE=0, REQUEST=1, PROCESS=2, END_PASS=3,
                     SORT01=4,SORT12=5,SORT02=6,CHECK_START=7,CHECK=8,PUBLISH=9;
    reg [3:0] state;
    (* ASYNC_REG="TRUE" *) reg sync1,sync2;
    reg sync_prev;
    reg [11:0] end_bin, scan_bin, best_bin;
    reg [31:0] best_mag, max_mag;
    reg [1:0] pass, count;
    reg [11:0] peak_bins[0:2];
    reg [31:0] mags[0:2];
    reg [11:0] remainder;
    reg [5:0] order;
    reg [1:0] check_index;
    reg consistent;
    integer i,j;
    reg excluded;
    always @* begin
        excluded=0;
        for(j=0;j<3;j=j+1)
            if(j<pass && ((scan_bin>peak_bins[j]) ?
               (scan_bin-peak_bins[j]<=EXCLUDE_BINS):(peak_bins[j]-scan_bin<=EXCLUDE_BINS))) excluded=1;
    end
    wire [31:0] relative_floor=max_mag>>RELATIVE_FLOOR_SHIFT;
    wire [31:0] threshold=(relative_floor>ABSOLUTE_FLOOR)?relative_floor:ABSOLUTE_FLOOR;
    wire larger=!excluded && rd_data>best_mag;
    wire [11:0] quantization_tolerance=({6'd0,order}>>1)+12'd2;
    assign rd_en=(state==REQUEST);
    assign busy=(state!=IDLE);
    always @(posedge clk) begin
        if(rst) begin
            sync1<=0;sync2<=0;sync_prev<=0;state<=IDLE;rd_addr<=20;
            scan_bin<=20;end_bin<=1000;best_bin<=0;best_mag<=0;max_mag<=0;
            pass<=0;count<=0;component_count<=0;component_bins<=0;component_magnitudes<=0;
            fundamental_bin<=0;fundamental_hz<=0;fundamental_magnitude<=0;
            harmonics_consistent<=0;result_valid<=0;remainder<=0;order<=0;check_index<=0;consistent<=1;
            for(i=0;i<3;i=i+1) begin peak_bins[i]<=12'hfff;mags[i]<=0;end
        end else begin
            sync1<=frame_done_toggle;sync2<=sync1;sync_prev<=sync2;result_valid<=0;
            case(state)
                IDLE: if(sync2!=sync_prev) begin
                    end_bin<=(mode==0)?400:1000;scan_bin<=20;rd_addr<=20;
                    best_mag<=0;best_bin<=0;max_mag<=0;pass<=0;count<=0;consistent<=1;
                    for(i=0;i<3;i=i+1) begin peak_bins[i]<=12'hfff;mags[i]<=0;end
                    state<=REQUEST;
                end
                REQUEST: state<=PROCESS;
                PROCESS: begin
                    if(larger) begin best_mag<=rd_data;best_bin<=scan_bin;end
                    if(scan_bin==end_bin) state<=END_PASS;
                    else begin scan_bin<=scan_bin+1'b1;rd_addr<=scan_bin+1'b1;state<=REQUEST;end
                end
                END_PASS: begin
                    if(best_mag<((pass==0)?ABSOLUTE_FLOOR:threshold) || best_mag==0) state<=SORT01;
                    else begin
                        peak_bins[pass]<=best_bin;mags[pass]<=best_mag;count<=count+1'b1;
                        if(pass==0) max_mag<=best_mag;
                        if(pass==2) state<=SORT01;
                        else begin
                            pass<=pass+1'b1;best_mag<=0;best_bin<=0;scan_bin<=20;rd_addr<=20;state<=REQUEST;
                        end
                    end
                end
                SORT01: begin
                    if(peak_bins[0]>peak_bins[1]) begin
                        peak_bins[0]<=peak_bins[1];peak_bins[1]<=peak_bins[0];mags[0]<=mags[1];mags[1]<=mags[0];
                    end
                    state<=SORT12;
                end
                SORT12: begin
                    if(peak_bins[1]>peak_bins[2]) begin
                        peak_bins[1]<=peak_bins[2];peak_bins[2]<=peak_bins[1];mags[1]<=mags[2];mags[2]<=mags[1];
                    end
                    state<=SORT02;
                end
                SORT02: begin
                    if(peak_bins[0]>peak_bins[1]) begin
                        peak_bins[0]<=peak_bins[1];peak_bins[1]<=peak_bins[0];mags[0]<=mags[1];mags[1]<=mags[0];
                    end
                    check_index<=1;state<=CHECK_START;
                end
                CHECK_START: begin
                    if(check_index>=count) state<=PUBLISH;
                    else begin remainder<=peak_bins[check_index];order<=0;state<=CHECK;end
                end
                CHECK: begin
                    if(remainder>=peak_bins[0]) begin remainder<=remainder-peak_bins[0];order<=order+1'b1;end
                    else begin
                        if(order==0 || ((remainder>quantization_tolerance) &&
                           (peak_bins[0]-remainder>quantization_tolerance))) consistent<=0;
                        check_index<=check_index+1'b1;state<=CHECK_START;
                    end
                end
                PUBLISH: begin
                    component_count<=count;
                    for(i=0;i<3;i=i+1) begin
                        component_bins[i*12 +: 12]<=(i<count)?peak_bins[i]:12'd0;
                        component_magnitudes[i*32 +: 32]<=(i<count)?mags[i]:32'd0;
                    end
                    harmonics_consistent<=consistent && count!=0;
                    fundamental_bin<=(count!=0 && consistent)?peak_bins[0]:12'd0;
                    fundamental_hz<=(count!=0 && consistent)?({20'd0,peak_bins[0]}*32'd500):32'd0;
                    fundamental_magnitude<=(count!=0 && consistent)?mags[0]:32'd0;
                    result_valid<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
