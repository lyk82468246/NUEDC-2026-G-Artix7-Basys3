`timescale 1ns / 1ps

//==============================================================================
// ADC_Input_CDC
//------------------------------------------------------------------------------
// Captures the parallel AD9226 bus in the forwarded ADC-clock domain and
// transfers one held sample at a time into the 100 MHz algorithm domain.
//
// The falling edge is used for the source capture so that the AD9226 has
// approximately half an ADC-clock period after the forwarded rising edge to
// settle its output bus.  The source holds the bus while a toggle crosses two
// synchronizer flops.  At 4.096 MHz, a sample remains stable for roughly 24
// algorithm-clock cycles, which is ample for this bundled-data CDC scheme.
//
// Only registers are clocked by the regional BUFR.  FIR/DSP/BRAM logic runs on
// calc_clk, which is the global 100 MHz clock, avoiding Artix-7 regional clock
// placement limits.
//==============================================================================
module ADC_Input_CDC #(
    parameter integer ADC_WIDTH = 12
)(
    input  wire                 adc_clk,
    input  wire                 rst_adc,
    input  wire [ADC_WIDTH-1:0] adc_data,

    input  wire                 calc_clk,
    input  wire                 rst_calc,
    output reg                  sample_valid_calc,
    output reg  [ADC_WIDTH-1:0] adc_data_calc
);

    reg [ADC_WIDTH-1:0] adc_data_hold;
    reg                  sample_toggle_adc;

    // Source-domain capture.  Reset is synchronous to the source edge used
    // by this block; the top-level reset remains asserted for several ADC
    // cycles after clock lock.
    always @(negedge adc_clk) begin
        if (rst_adc) begin
            adc_data_hold     <= {ADC_WIDTH{1'b0}};
            sample_toggle_adc <= 1'b0;
        end
        else begin
            adc_data_hold     <= adc_data;
            sample_toggle_adc <= ~sample_toggle_adc;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg sample_toggle_calc_ff1;
    (* ASYNC_REG = "TRUE" *) reg sample_toggle_calc_ff2;
    reg sample_toggle_calc_seen;

    always @(posedge calc_clk) begin
        if (rst_calc) begin
            sample_toggle_calc_ff1  <= 1'b0;
            sample_toggle_calc_ff2  <= 1'b0;
            sample_toggle_calc_seen <= 1'b0;
            sample_valid_calc       <= 1'b0;
            adc_data_calc           <= {ADC_WIDTH{1'b0}};
        end
        else begin
            sample_toggle_calc_ff1 <= sample_toggle_adc;
            sample_toggle_calc_ff2 <= sample_toggle_calc_ff1;
            sample_valid_calc      <= 1'b0;

            if (sample_toggle_calc_ff2 != sample_toggle_calc_seen) begin
                // The held bus has been stable since the source toggle and
                // is safe to sample after the two-flop event latency.
                adc_data_calc           <= adc_data_hold;
                sample_valid_calc       <= 1'b1;
                sample_toggle_calc_seen <= sample_toggle_calc_ff2;
            end
        end
    end

endmodule
