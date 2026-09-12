`timescale 1ns / 1ps

//==============================================================================
// Button_Debounce
//------------------------------------------------------------------------------
// Two-flop input synchronizer followed by a consecutive-sample debounce
// filter.  button_pulse is a one-clock pulse on a debounced rising edge.
//==============================================================================
module Button_Debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  button_state,
    output reg  button_pulse
);

    localparam integer DEBOUNCE_CYCLES_RAW =
        (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer DEBOUNCE_CYCLES =
        (DEBOUNCE_CYCLES_RAW < 1) ? 1 : DEBOUNCE_CYCLES_RAW;
    localparam integer COUNT_WIDTH =
        (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES + 1);

    (* ASYNC_REG = "TRUE" *) reg button_meta;
    (* ASYNC_REG = "TRUE" *) reg button_sync;
    reg [COUNT_WIDTH-1:0] stable_count;

    always @(posedge clk) begin
        if (rst) begin
            button_meta  <= 1'b0;
            button_sync  <= 1'b0;
            button_state <= 1'b0;
            button_pulse <= 1'b0;
            stable_count <= {COUNT_WIDTH{1'b0}};
        end
        else begin
            button_meta  <= button_in;
            button_sync  <= button_meta;
            button_pulse <= 1'b0;

            if (button_sync == button_state) begin
                stable_count <= {COUNT_WIDTH{1'b0}};
            end
            else if (DEBOUNCE_CYCLES <= 1) begin
                button_state <= button_sync;
                button_pulse <= button_sync;
                stable_count <= {COUNT_WIDTH{1'b0}};
            end
            else if (stable_count == DEBOUNCE_CYCLES-1) begin
                button_state <= button_sync;
                // Only a press generates an event; release merely rearms it.
                button_pulse <= button_sync;
                stable_count <= {COUNT_WIDTH{1'b0}};
            end
            else begin
                stable_count <= stable_count + 1'b1;
            end
        end
    end

endmodule
