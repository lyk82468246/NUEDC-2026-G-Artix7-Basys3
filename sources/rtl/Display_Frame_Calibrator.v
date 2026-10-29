`timescale 1ns/1ps
// Display-only numeric packet preparation; never feeds measurement algorithms.
// Gain format: unsigned Q16.16 reference microvolts/raw (NOT proof of absolute
// calibration). One multiplier is reused for Vpp/RMS/three PEAKs/wave Amax.
// All raw values, gains, frame ID and epoch are captured on ONE input handshake.
// Public results are published together, held until out_ready, never partially
// updated during conversion. Invalid/uncalibrated packets still complete.
module Display_Frame_Calibrator(
    input wire clk,rst,input wire in_valid,output wire in_ready,
    input wire signal_valid,calibration_valid,
    input wire [16:0] vpp_raw,input wire [15:0] rms_raw,amax_raw,
    input wire [1:0] component_count,input wire [35:0] component_bins,
    input wire [95:0] component_magnitudes,
    input wire [31:0] vpp_gain,rms_gain,fft_gain,frame_id,epoch,
    input wire [7:0] metadata,
    output reg out_valid,input wire out_ready,
    output reg [31:0] vpp_uv,rms_uv,amax_uv,
    output reg [95:0] peaks_uv,frequencies_hz,
    output reg [1:0] count_out,
    output reg [31:0] frame_id_out,epoch_out,
    output reg [7:0] metadata_out,
    output reg signal_valid_out,calibration_valid_out,voltage_valid,overflow
);
    localparam IDLE=0,MULTIPLY=1,SCALE=2,PUBLISH=3;
    reg [1:0] state;
    reg [2:0] field;
    reg [31:0] values[0:5],gains[0:5],converted[0:5];
    reg [63:0] product;
    wire [64:0] rounded={1'b0,product}+65'd32768;
    wire clipped=|rounded[64:48];
    reg source_ok,bank_ok,overflow_pending;
    reg [31:0] id_pending,epoch_pending;
    reg [1:0] count_pending;
    reg [95:0] frequencies_pending;
    reg [7:0] metadata_pending;
    integer i;
    assign in_ready=!rst && state==IDLE && !out_valid;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;field<=0;product<=0;out_valid<=0;
            source_ok<=0;bank_ok<=0;overflow_pending<=0;
            id_pending<=0;epoch_pending<=0;count_pending<=0;frequencies_pending<=0;metadata_pending<=0;
            vpp_uv<=0;rms_uv<=0;amax_uv<=0;peaks_uv<=0;frequencies_hz<=0;
            count_out<=0;frame_id_out<=0;epoch_out<=0;metadata_out<=0;
            signal_valid_out<=0;calibration_valid_out<=0;voltage_valid<=0;overflow<=0;
            for(i=0;i<6;i=i+1) begin values[i]<=0;gains[i]<=0;converted[i]<=0;end
        end else begin
            if(out_valid && out_ready) out_valid<=0;
            case(state)
                IDLE: if(in_valid && in_ready) begin
                    source_ok<=signal_valid && component_count!=0;
                    bank_ok<=calibration_valid && vpp_gain!=0 && rms_gain!=0 && fft_gain!=0;
                    overflow_pending<=0;id_pending<=frame_id;epoch_pending<=epoch;metadata_pending<=metadata;
                    count_pending<=signal_valid?component_count:2'd0;
                    values[0]<={15'd0,vpp_raw};values[1]<={16'd0,rms_raw};values[5]<={16'd0,amax_raw};
                    gains[0]<=vpp_gain;gains[1]<=rms_gain;gains[5]<=vpp_gain;
                    for(i=0;i<3;i=i+1) begin
                        values[i+2]<=(signal_valid && i<component_count)?component_magnitudes[i*32+:32]:32'd0;
                        gains[i+2]<=fft_gain;
                        frequencies_pending[i*32+:32]<=(signal_valid && i<component_count)?
                            ({20'd0,component_bins[i*12+:12]}*32'd500):32'd0;
                    end
                    for(i=0;i<6;i=i+1) converted[i]<=0;
                    field<=0;
                    if(signal_valid && component_count!=0 && calibration_valid &&
                       vpp_gain!=0 && rms_gain!=0 && fft_gain!=0) state<=MULTIPLY;
                    else state<=PUBLISH;
                end
                MULTIPLY: begin product<=values[field]*gains[field];state<=SCALE;end
                SCALE: begin
                    converted[field]<=clipped?32'hffffffff:rounded[47:16];
                    if(clipped) overflow_pending<=1;
                    if(field==5) state<=PUBLISH;
                    else begin field<=field+1'b1;state<=MULTIPLY;end
                end
                PUBLISH: begin
                    vpp_uv<=converted[0];rms_uv<=converted[1];amax_uv<=converted[5];
                    peaks_uv<={converted[4],converted[3],converted[2]};frequencies_hz<=frequencies_pending;
                    count_out<=count_pending;frame_id_out<=id_pending;epoch_out<=epoch_pending;
                    metadata_out<={metadata_pending[7:2],bank_ok,source_ok};
                    signal_valid_out<=source_ok;calibration_valid_out<=bank_ok;
                    overflow<=overflow_pending;voltage_valid<=source_ok && bank_ok && !overflow_pending;
                    out_valid<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
