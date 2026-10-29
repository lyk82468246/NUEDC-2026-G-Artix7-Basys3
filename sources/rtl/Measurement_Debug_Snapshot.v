`timescale 1ns/1ps
// Read-only observation sidecar, all ports synchronous to clk_algo.
// Input commit is the HMI's post-qualification measurement_valid event.
// NBA-updated data and valid become visible together on the following cycle;
// ILA must trigger on measurement_valid_out, NOT the original commit signal.
// Epoch is the active bank sampled on the same edge as Runtime_Calibration's
// sample_valid. A bank request on that edge is deferred by that module.
module Measurement_Debug_Snapshot(
    input wire clk, rst, commit,
    input wire signal_valid,
    input wire [16:0] vpp_raw,
    input wire [15:0] rms_raw,
    input wire [31:0] fundamental_raw,
    input wire [11:0] fundamental_bin,
    input wire [1:0] component_count,
    input wire [35:0] component_bins,
    input wire [95:0] component_magnitudes,
    input wire [31:0] frame_id, calibration_epoch,
    input wire calibration_enabled, calibration_present,
    input wire [1:0] mode,
    input wire single_mode, three_cycles,
    output reg measurement_valid_out,
    output reg [16:0] vpp_out,
    output reg [15:0] rms_out,
    output reg [31:0] fundamental_out,
    output reg [11:0] fundamental_bin_out,
    output reg [1:0] component_count_out,
    output reg [35:0] component_bins_out,
    output reg [95:0] component_magnitudes_out,
    output reg [31:0] frame_id_out, calibration_epoch_out,
    // bit0 valid signal, bit1 enabled calibration, bit2 VIO present,
    // bits4:3 mode, bit5 single, bit6 three cycles, bit7 reserved zero.
    output reg [7:0] metadata_out
);
    integer slot;
    always @(posedge clk) begin
        if(rst) begin
            measurement_valid_out<=0;vpp_out<=0;rms_out<=0;
            fundamental_out<=0;fundamental_bin_out<=0;
            component_count_out<=0;component_bins_out<=0;component_magnitudes_out<=0;
            frame_id_out<=0;calibration_epoch_out<=0;metadata_out<=0;
        end else begin
            measurement_valid_out<=commit;
            if(commit) begin
                vpp_out<=vpp_raw;rms_out<=rms_raw;
                frame_id_out<=frame_id;
                calibration_epoch_out<=calibration_present?calibration_epoch:32'd0;
                metadata_out<={1'b0,three_cycles,single_mode,mode,
                               calibration_present,calibration_enabled,signal_valid};
                fundamental_out<=signal_valid?fundamental_raw:32'd0;
                fundamental_bin_out<=signal_valid?fundamental_bin:12'd0;
                component_count_out<=signal_valid?component_count:2'd0;
                // Packed order is low slot first: bins[11:0], mags[31:0].
                // Mask unused slots even if an upstream register retained data.
                for(slot=0;slot<3;slot=slot+1) begin
                    component_bins_out[slot*12+:12]<=
                        (signal_valid && slot<component_count)?component_bins[slot*12+:12]:12'd0;
                    component_magnitudes_out[slot*32+:32]<=
                        (signal_valid && slot<component_count)?component_magnitudes[slot*32+:32]:32'd0;
                end
            end
        end
    end
endmodule
