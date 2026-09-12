`timescale 1ns / 1ps

//==============================================================================
// Reset_Synchronizer
//------------------------------------------------------------------------------
// Asynchronous assertion and synchronous deassertion of a reset in one clock
// domain.  The top-level reset is asserted by the pushbutton or MMCM lock
// loss; releasing it through this block avoids recovery/removal violations.
//==============================================================================
module Reset_Synchronizer (
    input  wire clk,
    input  wire arst,
    output wire srst
);

    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_ff;

    always @(posedge clk or posedge arst) begin
        if (arst)
            sync_ff <= 2'b11;
        else
            sync_ff <= {sync_ff[0], 1'b0};
    end

    assign srst = sync_ff[1];

endmodule
