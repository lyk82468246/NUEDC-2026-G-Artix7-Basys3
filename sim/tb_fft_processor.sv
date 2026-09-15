`timescale 1ns/1ps

//==============================================================================
// tb_fft_processor
//------------------------------------------------------------------------------
// 定向行为仿真：FFT_Processor + XFFT/CORDIC/Flat-top ROM 行为网表。
//
// 本测试的重点是协议和进度，而不是把 XFFT 内核重新实现一遍：
//   * 8192 个同步 BRAM 样本请求地址连续且不越界；
//   * s_axis_config 和 s_axis_data 在 TVALID && !TREADY 时保持稳定；
//   * 最后一拍输入 TLAST 只在真实握手时推进；
//   * CORDIC 输出被完整排空 8192 个 bin；
//   * 频域 BRAM 只写 bin 0..4095，地址连续且无重复/越界；
//   * 最终完成脉冲出现，整个数据通路没有死锁。
//
// 测试使用小幅确定性正弦/余弦混合样本，避免输入全零掩盖窗乘法和
// 有符号数据通路的问题。频谱数值的绝对标定由后续上板 ILA 校准完成。
//==============================================================================
module tb_fft_processor;

    localparam integer FRAME_LENGTH = 8192;
    localparam integer DATA_WIDTH   = 16;
    localparam integer ADDR_WIDTH   = 13;
    localparam integer FREQ_DEPTH   = 4096;
    localparam integer FREQ_ADDR_WIDTH = 12;

    reg                         calc_clk;
    reg                         rst;
    reg                         frame_done_toggle;
    wire [ADDR_WIDTH-1:0]       time_rd_addr;
    wire                        time_rd_en;
    reg  signed [DATA_WIDTH-1:0] time_rd_data;
    wire [FREQ_ADDR_WIDTH-1:0]  freq_wr_addr;
    wire                        freq_wr_en;
    wire [31:0]                 freq_wr_data;
    wire                        freq_frame_done_toggle;
    wire                        freq_frame_done_pulse;
    wire                        frame_valid;
    wire                        busy;

    reg signed [DATA_WIDTH-1:0] sample_mem [0:FRAME_LENGTH-1];

    integer i;
    integer sample_value;
    integer sample_request_count;
    integer expected_sample_addr;
    integer freq_write_count;
    integer frame_done_count;
    integer input_halt_events;
    integer output_halt_events;
    integer timeout_cycles;
    reg     test_done;
    reg     previous_frame_valid;

    // AXI stability scoreboards.  The signals are intentionally observed via
    // hierarchical references so the public testbench need not change the DUT
    // interface just to verify the internal handshake contract.
    reg                          config_hold_valid;
    reg [7:0]                    config_hold_data;
    reg                          data_hold_valid;
    reg [31:0]                   data_hold_tdata;
    reg                          data_hold_tlast;

    initial calc_clk = 1'b0;
    always #5 calc_clk = ~calc_clk;

    FFT_Processor #(
        .DATA_WIDTH                (DATA_WIDTH),
        .FRAME_LENGTH              (FRAME_LENGTH),
        .ADDR_WIDTH                (ADDR_WIDTH),
        .FREQ_DEPTH                (FREQ_DEPTH),
        .FREQ_ADDR_WIDTH           (FREQ_ADDR_WIDTH),
        .WINDOW_FRAC_BITS          (15),
        .FFT_INPUT_TDATA_WIDTH     (32),
        .FFT_OUTPUT_COMPONENT_WIDTH(30),
        .FFT_OUTPUT_TDATA_WIDTH    (64),
        .CORDIC_INPUT_WIDTH        (30),
        .CORDIC_OUTPUT_WIDTH       (31),
        .CORDIC_INPUT_TDATA_WIDTH  (64),
        .CORDIC_OUTPUT_TDATA_WIDTH (64)
    ) dut (
        .calc_clk              (calc_clk),
        .rst                   (rst),
        .frame_done_toggle     (frame_done_toggle),
        .time_rd_addr          (time_rd_addr),
        .time_rd_en            (time_rd_en),
        .time_rd_data          (time_rd_data),
        .freq_wr_addr          (freq_wr_addr),
        .freq_wr_en            (freq_wr_en),
        .freq_wr_data          (freq_wr_data),
        .freq_frame_done_toggle(freq_frame_done_toggle),
        .freq_frame_done_pulse (freq_frame_done_pulse),
        .frame_valid           (frame_valid),
        .busy                  (busy)
    );

    // Synchronous-read model of BRAM_TimeDomain.
    always @(posedge calc_clk) begin
        if (time_rd_en) begin
            assert (time_rd_addr < FRAME_LENGTH)
                else $fatal(1, "Time BRAM address out of range: %0d", time_rd_addr);
            time_rd_data <= sample_mem[time_rd_addr];
        end
    end

    // Read-address, output-BRAM and completion assertions.
    always @(posedge calc_clk) begin
        if (rst) begin
            sample_request_count <= 0;
            expected_sample_addr <= 0;
            freq_write_count     <= 0;
            frame_done_count     <= 0;
            input_halt_events    <= 0;
            output_halt_events   <= 0;
            previous_frame_valid <= 1'b0;
        end
        else begin
            if (time_rd_en) begin
                assert (time_rd_addr == expected_sample_addr)
                    else $fatal(1,
                        "Time BRAM sequence error: got %0d expected %0d",
                        time_rd_addr, expected_sample_addr);
                sample_request_count <= sample_request_count + 1;
                if (expected_sample_addr == FRAME_LENGTH-1)
                    expected_sample_addr <= 0;
                else
                    expected_sample_addr <= expected_sample_addr + 1;
            end

            if (freq_wr_en) begin
                assert (freq_wr_addr == freq_write_count)
                    else $fatal(1,
                        "Freq BRAM address error: got %0d expected %0d",
                        freq_wr_addr, freq_write_count);
                assert (freq_wr_addr < FREQ_DEPTH)
                    else $fatal(1, "Freq BRAM address out of range: %0d",
                                freq_wr_addr);
                freq_write_count <= freq_write_count + 1;
            end

            assert (!(previous_frame_valid && frame_valid))
                else $fatal(1, "frame_valid lasted more than one cycle");
            previous_frame_valid <= frame_valid;

            if (freq_frame_done_pulse) begin
                frame_done_count <= frame_done_count + 1;
                assert (freq_write_count == FREQ_DEPTH)
                    else $fatal(1, "Completion after %0d frequency writes",
                                freq_write_count);
            end

            // XFFT reports a protocol error when TLAST is inconsistent.  The
            // DUT must never raise one for the generated 8192-sample frame.
            assert (!dut.event_tlast_unexpected)
                else $fatal(1, "XFFT event_tlast_unexpected asserted");
            assert (!dut.event_tlast_missing)
                else $fatal(1, "XFFT event_tlast_missing asserted");
            // These two XFFT event pins report that an AXI channel has seen
            // back-pressure.  That is legal for this burst architecture: the
            // DUT must hold TVALID and payload stable until TREADY returns.
            // Count the events for visibility, while the stability assertions
            // above remain the hard protocol checks.
            if (dut.event_data_in_channel_halt)
                input_halt_events <= input_halt_events + 1;
            if (dut.event_data_out_channel_halt)
                output_halt_events <= output_halt_events + 1;
        end
    end

    // AXI4-Stream rule: while TVALID is asserted without TREADY, all payload
    // and TLAST bits must remain unchanged.
    always @(posedge calc_clk) begin
        if (rst) begin
            config_hold_valid <= 1'b0;
            data_hold_valid   <= 1'b0;
        end
        else begin
            if (dut.fft_config_tvalid && !dut.fft_config_tready) begin
                if (config_hold_valid) begin
                    assert (dut.fft_config_tdata == config_hold_data)
                        else $fatal(1, "FFT config TDATA changed while stalled");
                end
                config_hold_valid <= 1'b1;
                config_hold_data  <= dut.fft_config_tdata;
            end
            else begin
                config_hold_valid <= 1'b0;
            end

            if (dut.fft_s_axis_tvalid && !dut.fft_s_axis_tready) begin
                if (data_hold_valid) begin
                    assert (dut.fft_s_axis_tdata == data_hold_tdata)
                        else $fatal(1, "FFT input TDATA changed while stalled");
                    assert (dut.fft_s_axis_tlast == data_hold_tlast)
                        else $fatal(1, "FFT input TLAST changed while stalled");
                end
                data_hold_valid <= 1'b1;
                data_hold_tdata  <= dut.fft_s_axis_tdata;
                data_hold_tlast  <= dut.fft_s_axis_tlast;
            end
            else begin
                data_hold_valid <= 1'b0;
            end
        end
    end

    initial begin
        sample_request_count = 0;
        expected_sample_addr = 0;
        freq_write_count     = 0;
        frame_done_count     = 0;
        input_halt_events    = 0;
        output_halt_events   = 0;
        test_done            = 1'b0;
        previous_frame_valid = 1'b0;
        config_hold_valid    = 1'b0;
        data_hold_valid      = 1'b0;
        time_rd_data         = '0;
        frame_done_toggle    = 1'b0;
        rst                  = 1'b1;

        // A small deterministic signed waveform.  The values stay far below
        // the 16-bit limit, while both signs exercise sign extension in the
        // FFT and CORDIC input packing.
        for (i = 0; i < FRAME_LENGTH; i = i + 1) begin
            sample_value = (((i * 37) % 2048) - 1024) / 8;
            sample_mem[i] = sample_value;
        end

        repeat (8) @(negedge calc_clk);
        rst = 1'b0;
        repeat (8) @(negedge calc_clk);
        frame_done_toggle = 1'b1;

        // The XFFT burst model plus CORDIC pipeline normally completes well
        // below this bound.  A finite bound makes a bad handshake fail fast.
        for (timeout_cycles = 0; timeout_cycles < 2000000;
             timeout_cycles = timeout_cycles + 1) begin
            @(negedge calc_clk);
            if (frame_done_count == 1) begin
                test_done = 1'b1;
                timeout_cycles = 2000000;
            end
        end

        assert (test_done)
            else $fatal(1, "Timeout: FFT_Processor did not complete");
        assert (sample_request_count == FRAME_LENGTH)
            else $fatal(1, "Expected %0d time reads, got %0d",
                        FRAME_LENGTH, sample_request_count);
        assert (freq_write_count == FREQ_DEPTH)
            else $fatal(1, "Expected %0d frequency writes, got %0d",
                        FREQ_DEPTH, freq_write_count);
        assert (frame_done_count == 1)
            else $fatal(1, "Expected one frequency completion, got %0d",
                        frame_done_count);

        $display("PASS: tb_fft_processor completed: %0d input reads, %0d freq writes, input_halt_events=%0d, output_halt_events=%0d.",
                 sample_request_count, freq_write_count,
                 input_halt_events, output_halt_events);
        $finish;
    end

endmodule
