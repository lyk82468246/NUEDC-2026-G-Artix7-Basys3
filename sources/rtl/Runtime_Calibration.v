`timescale 1ns/1ps
// Online calibration sidecar. All signals belong to clk (VIO uses same clock).
// Gains: unsigned Q16.16, reference microvolts/raw. FFT means sine PEAK,
// NOT Vpp or RMS. No guessed defaults: reset bank is disabled with zero gains.
// Host writes staging bank FIRST, commits it, then toggles request separately.
// Keep staging stable until ack==request. No request may be pipelined.
// A request is accepted only between packets. Every job snapshots its epoch,
// gains and values, so an update cannot mix old/new coefficients within a job.
module Runtime_Calibration(
    input wire clk, rst,
    input wire request_toggle, staging_valid,
    input wire [31:0] staging_vpp_gain, staging_rms_gain, staging_fft_gain,
    input wire sample_valid, signal_valid,
    input wire [16:0] vpp_raw,
    input wire [15:0] rms_raw,
    input wire [31:0] fft_raw,
    output reg ack_toggle,
    output reg [31:0] epoch, result_epoch, result_count,
    output reg [31:0] active_vpp_gain, active_rms_gain, active_fft_gain,
    output reg active_valid,
    output reg [31:0] vpp_uv, rms_uv, peak_uv,
    output reg valid, overflow, busy, done, overrun
);
    localparam IDLE=0, MULTIPLY=1, ROUND=2;
    reg [1:0] state;
    reg [1:0] field;
    reg req_d1, req_d2;
    reg [31:0] values[0:2], gains[0:2];
    reg [63:0] product;
    wire [64:0] rounded={1'b0,product}+65'd32768;
    wire clipped=|rounded[64:48];
    wire [31:0] converted=clipped?32'hffffffff:rounded[47:16];
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            req_d1<=0;req_d2<=0;ack_toggle<=0;epoch<=0;result_epoch<=0;
            result_count<=0;active_vpp_gain<=0;active_rms_gain<=0;
            active_fft_gain<=0;active_valid<=0;
            state<=IDLE;field<=0;product<=0;
            vpp_uv<=0;rms_uv<=0;peak_uv<=0;
            valid<=0;overflow<=0;busy<=0;done<=0;overrun<=0;
            for(i=0;i<3;i=i+1) begin values[i]<=0;gains[i]<=0;end
        end else begin
            req_d1<=request_toggle;req_d2<=req_d1;done<=0;
            if(sample_valid && busy) overrun<=1; // sticky protocol diagnostic
            case(state)
                IDLE: begin
                    if(sample_valid) begin
                        valid<=0;overflow<=0;vpp_uv<=0;rms_uv<=0;peak_uv<=0;
                        result_epoch<=epoch;
                        if(!active_valid || !signal_valid) begin
                            done<=1;result_count<=result_count+1'b1;
                        end else begin
                            values[0]<={15'd0,vpp_raw};values[1]<={16'd0,rms_raw};values[2]<=fft_raw;
                            gains[0]<=active_vpp_gain;gains[1]<=active_rms_gain;gains[2]<=active_fft_gain;
                            field<=0;busy<=1;state<=MULTIPLY;
                        end
                    end else if(req_d2!=ack_toggle) begin
                        active_vpp_gain<=staging_vpp_gain;
                        active_rms_gain<=staging_rms_gain;
                        active_fft_gain<=staging_fft_gain;
                        active_valid<=staging_valid && staging_vpp_gain!=0 &&
                                      staging_rms_gain!=0 && staging_fft_gain!=0;
                        epoch<=epoch+1'b1;ack_toggle<=req_d2;
                        // Last result remains tagged with result_epoch, not epoch.
                        // It must not be reinterpreted using the new bank.
                    end
                end
                MULTIPLY: begin product<=values[field]*gains[field];state<=ROUND;end
                ROUND: begin
                    if(clipped) overflow<=1;
                    case(field)
                        0:vpp_uv<=converted;
                        1:rms_uv<=converted;
                        2:peak_uv<=converted;
                    endcase
                    if(field==2) begin
                        valid<=1;done<=1;busy<=0;result_count<=result_count+1'b1;state<=IDLE;
                    end else begin field<=field+1'b1;state<=MULTIPLY;end
                end
                default:begin state<=IDLE;busy<=0;valid<=0;end
            endcase
        end
    end
endmodule
