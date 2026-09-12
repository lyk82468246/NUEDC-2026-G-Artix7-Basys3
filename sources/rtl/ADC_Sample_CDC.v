`timescale 1ns / 1ps

//==============================================================================
// ADC_Sample_CDC
//------------------------------------------------------------------------------
// Transfers the sparse ADC-frame write stream from the regional ADC clock
// domain into the 100 MHz algorithm clock domain without making a block RAM
// write port depend on a BUFR.  The source rate is at most one sample per ADC
// clock (about 4.096 MHz), while the destination is 100 MHz, so a held-data /
// toggle handshake is sufficient and has ample settling time for the bus.
//
// The source holds address/data until the next sample.  The toggle is passed
// through two destination flip-flops; when the destination observes a change,
// it captures the already-settled multi-bit bus and produces a one-cycle write
// pulse.  The source and destination clocks are unrelated for CDC purposes,
// even though the current implementation has a known frequency relationship.
//
// Frame completion is also transferred as a toggle.  The destination delays
// its own completion toggle until the final address has actually been
// presented to the BRAM write port, so downstream calculation cannot start
// before sample 8191 is committed.
//==============================================================================
module ADC_Sample_CDC #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer ADDR_WIDTH   = 13,
    parameter integer FRAME_LENGTH = 8192
)(
    input  wire                         src_clk,
    input  wire                         src_rst,
    input  wire                         sample_valid_src,
    input  wire [ADDR_WIDTH-1:0]        sample_addr_src,
    input  wire signed [DATA_WIDTH-1:0] sample_data_src,
    input  wire                         frame_done_toggle_src,

    input  wire                         dst_clk,
    input  wire                         dst_rst,
    output reg                          wr_en_dst,
    output reg  [ADDR_WIDTH-1:0]        wr_addr_dst,
    output reg  signed [DATA_WIDTH-1:0] wr_data_dst,
    output reg                          frame_done_toggle_dst,
    output reg                          frame_done_pulse_dst
);

    localparam [ADDR_WIDTH-1:0] LAST_FRAME_ADDR = FRAME_LENGTH - 1;

    //-------------------------------------------------------------------------
    // Source domain: hold the multi-bit payload and toggle once per sample.
    //-------------------------------------------------------------------------
    reg                          sample_toggle_src;
    reg [ADDR_WIDTH-1:0]         sample_addr_hold_src;
    reg signed [DATA_WIDTH-1:0] sample_data_hold_src;

    always @(posedge src_clk) begin
        if (src_rst) begin
            sample_toggle_src   <= 1'b0;
            sample_addr_hold_src <= {ADDR_WIDTH{1'b0}};
            sample_data_hold_src <= {DATA_WIDTH{1'b0}};
        end
        else if (sample_valid_src) begin
            sample_addr_hold_src <= sample_addr_src;
            sample_data_hold_src <= sample_data_src;
            sample_toggle_src    <= ~sample_toggle_src;
        end
    end

    //-------------------------------------------------------------------------
    // Destination domain: synchronize event toggles and generate BRAM writes.
    //-------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg sample_toggle_dst_ff1;
    (* ASYNC_REG = "TRUE" *) reg sample_toggle_dst_ff2;
    reg sample_toggle_dst_seen;

    (* ASYNC_REG = "TRUE" *) reg frame_toggle_dst_ff1;
    (* ASYNC_REG = "TRUE" *) reg frame_toggle_dst_ff2;
    reg frame_toggle_dst_seen;
    reg frame_pending_dst;

    // This is the write request that the BRAM sees at the current dst_clk
    // edge.  It intentionally uses the registered output from the previous
    // edge, matching the synchronous BRAM interface.
    wire last_write_commit = wr_en_dst &&
                             (wr_addr_dst == LAST_FRAME_ADDR);

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            sample_toggle_dst_ff1 <= 1'b0;
            sample_toggle_dst_ff2 <= 1'b0;
            sample_toggle_dst_seen <= 1'b0;
            frame_toggle_dst_ff1  <= 1'b0;
            frame_toggle_dst_ff2  <= 1'b0;
            frame_toggle_dst_seen <= 1'b0;
            frame_pending_dst     <= 1'b0;

            wr_en_dst             <= 1'b0;
            wr_addr_dst           <= {ADDR_WIDTH{1'b0}};
            wr_data_dst           <= {DATA_WIDTH{1'b0}};
            frame_done_toggle_dst <= 1'b0;
            frame_done_pulse_dst  <= 1'b0;
        end
        else begin
            sample_toggle_dst_ff1 <= sample_toggle_src;
            sample_toggle_dst_ff2 <= sample_toggle_dst_ff1;
            frame_toggle_dst_ff1  <= frame_done_toggle_src;
            frame_toggle_dst_ff2  <= frame_toggle_dst_ff1;

            wr_en_dst            <= 1'b0;
            frame_done_pulse_dst <= 1'b0;

            if (sample_toggle_dst_ff2 != sample_toggle_dst_seen) begin
                // Payload has been stable since the source changed its
                // toggle, and has therefore had two dst_clk cycles to settle.
                wr_addr_dst           <= sample_addr_hold_src;
                wr_data_dst           <= sample_data_hold_src;
                wr_en_dst             <= 1'b1;
                sample_toggle_dst_seen <= sample_toggle_dst_ff2;
            end

            if (frame_toggle_dst_ff2 != frame_toggle_dst_seen) begin
                frame_toggle_dst_seen <= frame_toggle_dst_ff2;
                frame_pending_dst     <= 1'b1;
            end

            // The last sample write is committed by the BRAM at this edge.
            // Toggle only after observing that request, with a further
            // destination-clock margin for downstream synchronous readers.
            if (frame_pending_dst && last_write_commit) begin
                frame_pending_dst     <= 1'b0;
                frame_done_toggle_dst <= ~frame_done_toggle_dst;
                frame_done_pulse_dst  <= 1'b1;
            end
        end
    end

endmodule
