`timescale 1ns/1ps
// FIR is intentionally a one-cycle identity stub here: isolate the AFE DC
// estimator, signed arithmetic, zero crossing and rearm/release behavior.
module fir_compiler_lp_600k (
    input aclk, input aresetn,
    input s_axis_data_tvalid, output s_axis_data_tready,
    input [15:0] s_axis_data_tdata,
    output reg m_axis_data_tvalid, input m_axis_data_tready,
    output reg [15:0] m_axis_data_tdata
);
    assign s_axis_data_tready = m_axis_data_tready;
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_data_tvalid <= 0;
            m_axis_data_tdata <= 0;
        end else begin
            m_axis_data_tvalid <= s_axis_data_tvalid && s_axis_data_tready;
            if (s_axis_data_tvalid && s_axis_data_tready)
                m_axis_data_tdata <= s_axis_data_tdata;
        end
    end
endmodule

module tb_afe_small_signal;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, sample_valid = 0, release_frame = 0;
    reg [11:0] adc_data = 2048;
    wire wr_en, done, start;
    wire [7:0] wr_addr;
    wire signed [15:0] wr_data;
    integer sample_number = 0;
    integer post_frames = 0, post_samples = 0;
    integer signed post_sum = 0;
    integer minimum = 32767, maximum = -32768;
    AFE_Capture #(.FRAME_LENGTH(256), .ADDR_WIDTH(8)) dut (
        .adc_clk(clk), .rst(rst), .adc_data(adc_data), .sample_valid(sample_valid),
        .frame_release(release_frame), .bram_wr_en(wr_en), .bram_wr_addr(wr_addr),
        .bram_wr_data(wr_data), .frame_done_toggle(), .frame_done_pulse(done),
        .frame_start_pulse(start), .capture_busy()
    );
    always @(posedge clk) begin
        if (rst) release_frame <= 0;
        else begin
            if (done) release_frame <= 1;
            if (start) release_frame <= 0;
            if (sample_number > 45000) begin
                if (done) post_frames = post_frames + 1;
                if (wr_en) begin
                    post_samples = post_samples + 1;
                    post_sum = post_sum + $signed(wr_data);
                    if ($signed(wr_data) < minimum) minimum = $signed(wr_data);
                    if ($signed(wr_data) > maximum) maximum = $signed(wr_data);
                end
            end
        end
    end
    initial begin
        repeat (10) @(negedge clk);
        rst = 0;
        for (sample_number = 0; sample_number < 65000; sample_number = sample_number + 1) begin
            // Symmetric periodic signal: 0,+400,0,-400 at FIR output.
            case (sample_number % 4)
                1: adc_data = 2048 + 25;
                3: adc_data = 2048 - 25;
                default: adc_data = 2048;
            endcase
            // A single negative excursion exposes the old integer IIR trap:
            // after it, the estimator can sit below every future sample.
            if (sample_number == 35000) adc_data = 2048 - 26;
            sample_valid = 1;
            @(negedge clk);
            sample_valid = 0;
            repeat (2) @(negedge clk);
        end
        repeat (20) @(negedge clk);
        $display("AFE: post_frames=%0d samples=%0d sum=%0d min=%0d max=%0d",
                  post_frames, post_samples, post_sum, minimum, maximum);
        if (post_frames < 20) $fatal(1, "Small-signal capture stopped after isolated negative excursion");
        if (post_samples == 0) $fatal(1, "No output samples");
        if ((post_sum > post_samples*2) || (post_sum < -post_samples*2))
            $fatal(1, "AFE residual DC exceeds 2 raw LSB");
        if ((minimum > -390) || (maximum < 390))
            $fatal(1, "AC output does not retain both polarities");
        $display("PASS: tb_afe_small_signal continuous rearm and near-zero mean");
        $finish;
    end
endmodule
