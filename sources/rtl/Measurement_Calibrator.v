`timescale 1ns/1ps
// Time-multiplexed fixed point gain for Vpp, RMS, then THREE peak components.
// gain_time_q24 and gain_fft_q24 have units mV/raw, unsigned Q8.24.
// Gains are latched with the raw snapshot. No guessed calibration defaults.
// Uncalibrated inputs yield valid=0 and zero outputs; callers must display RAW
// explicitly or --, never relabel raw FFT bins as mV. Overflow is sticky per job.
module Measurement_Calibrator(
    input wire clk,rst,start,calibration_valid,
    input wire [31:0] gain_time_q24,gain_fft_q24,
    input wire [16:0] vpp_raw,
    input wire [15:0] rms_raw,
    input wire [95:0] component_raw,
    output reg [31:0] vpp_mv,rms_mv,
    output reg [95:0] component_peak_mv,
    output reg valid,overflow,busy,done
);
    localparam [1:0] IDLE=0,MULTIPLY=1,ROUND=2;
    reg [1:0] state;
    reg [2:0] field;
    reg [31:0] values[0:4];
    reg [31:0] time_gain,fft_gain;
    reg [63:0] product;
    wire [64:0] rounded={1'b0,product}+65'd8388608;
    wire clipped=|rounded[64:56];
    wire [31:0] mv=clipped?32'hffff_ffff:rounded[55:24];
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;field<=0;time_gain<=0;fft_gain<=0;product<=0;
            vpp_mv<=0;rms_mv<=0;component_peak_mv<=0;valid<=0;overflow<=0;busy<=0;done<=0;
            for(i=0;i<5;i=i+1) values[i]<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    valid<=0;overflow<=0;vpp_mv<=0;rms_mv<=0;component_peak_mv<=0;
                    if(!calibration_valid) done<=1;
                    else begin
                        values[0]<={15'd0,vpp_raw};values[1]<={16'd0,rms_raw};
                        for(i=0;i<3;i=i+1) values[i+2]<=component_raw[i*32 +: 32];
                        time_gain<=gain_time_q24;fft_gain<=gain_fft_q24;
                        field<=0;busy<=1;state<=MULTIPLY;
                    end
                end
                MULTIPLY: begin product<=values[field]*((field<2)?time_gain:fft_gain);state<=ROUND;end
                ROUND: begin
                    if(clipped) overflow<=1;
                    case(field)
                        0:vpp_mv<=mv;
                        1:rms_mv<=mv;
                        default:component_peak_mv[(field-2)*32 +: 32]<=mv;
                    endcase
                    if(field==4) begin valid<=1;done<=1;busy<=0;state<=IDLE;end
                    else begin field<=field+1'b1;state<=MULTIPLY;end
                end
                default:begin state<=IDLE;busy<=0;valid<=0;end
            endcase
        end
    end
endmodule
