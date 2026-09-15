`timescale 1ns/1ps

//==============================================================================
// tb_peak_search
//------------------------------------------------------------------------------
// 自检式 Peak_Search 行为仿真：验证同步频域 BRAM 扫描、最大值锁存、
// 地址范围 10..4000、f1=index*500 以及幅值缩放参数。
//==============================================================================
module tb_peak_search;

    localparam integer FREQ_DEPTH      = 4096;
    localparam integer FREQ_ADDR_WIDTH = 12;
    localparam integer SEARCH_START    = 10;
    localparam integer SEARCH_END      = 4000;
    localparam integer PEAK_INDEX      = 123;
    localparam integer PEAK_MAGNITUDE  = 5000;

    reg                         calc_clk;
    reg                         rst;
    reg                         frame_done_toggle;
    wire [FREQ_ADDR_WIDTH-1:0] freq_rd_addr;
    wire                        freq_rd_en;
    reg  [31:0]                 freq_rd_data;
    wire [FREQ_ADDR_WIDTH-1:0] max_index;
    wire [31:0]                 f1_hz;
    wire [31:0]                 amp_f1;
    wire                        result_valid;
    wire                        busy;

    reg [31:0] freq_mem [0:FREQ_DEPTH-1];
    integer i;
    integer read_count;
    integer expected_addr;
    integer result_count;
    integer timeout_cycles;
    reg     test_done;
    reg     previous_result_valid;

    initial calc_clk = 1'b0;
    always #5 calc_clk = ~calc_clk;

    Peak_Search #(
        .FREQ_DEPTH      (FREQ_DEPTH),
        .FREQ_ADDR_WIDTH (FREQ_ADDR_WIDTH),
        .SEARCH_START    (SEARCH_START),
        .SEARCH_END      (SEARCH_END),
        .PEAK_THRESHOLD  (100),
        .MAG_SCALE_FACTOR(2)
    ) dut (
        .calc_clk         (calc_clk),
        .rst              (rst),
        .frame_done_toggle(frame_done_toggle),
        .freq_rd_addr     (freq_rd_addr),
        .freq_rd_en       (freq_rd_en),
        .freq_rd_data     (freq_rd_data),
        .max_index        (max_index),
        .f1_hz            (f1_hz),
        .amp_f1           (amp_f1),
        .result_valid     (result_valid),
        .busy             (busy)
    );

    // Synchronous BRAM model.
    always @(posedge calc_clk) begin
        if (freq_rd_en) begin
            assert ((freq_rd_addr >= SEARCH_START) &&
                    (freq_rd_addr <= SEARCH_END))
                else $fatal(1, "Peak scan address out of range: %0d",
                            freq_rd_addr);
            freq_rd_data <= freq_mem[freq_rd_addr];
        end
    end

    always @(posedge calc_clk) begin
        if (rst) begin
            read_count          <= 0;
            expected_addr      <= SEARCH_START;
            result_count       <= 0;
            previous_result_valid <= 1'b0;
        end
        else begin
            if (freq_rd_en) begin
                assert (freq_rd_addr == expected_addr)
                    else $fatal(1, "Peak address sequence error: got %0d expected %0d",
                                freq_rd_addr, expected_addr);
                read_count <= read_count + 1;
                if (expected_addr == SEARCH_END)
                    expected_addr <= SEARCH_START;
                else
                    expected_addr <= expected_addr + 1;
            end

            assert (!(previous_result_valid && result_valid))
                else $fatal(1, "Peak result_valid lasted more than one cycle");
            previous_result_valid <= result_valid;

            if (result_valid) begin
                result_count <= result_count + 1;
                assert (max_index == PEAK_INDEX)
                    else $fatal(1, "max_index mismatch: got %0d expected %0d",
                                max_index, PEAK_INDEX);
                assert (f1_hz == PEAK_INDEX * 500)
                    else $fatal(1, "f1_hz mismatch: got %0d expected %0d",
                                f1_hz, PEAK_INDEX * 500);
                assert (amp_f1 == PEAK_MAGNITUDE * 2)
                    else $fatal(1, "amp_f1 mismatch: got %0d expected %0d",
                                amp_f1, PEAK_MAGNITUDE * 2);
                test_done <= 1'b1;
            end
        end
    end

    initial begin
        read_count             = 0;
        expected_addr         = SEARCH_START;
        result_count          = 0;
        previous_result_valid = 1'b0;
        test_done             = 1'b0;
        freq_rd_data          = 32'd0;
        frame_done_toggle     = 1'b0;
        rst                   = 1'b1;

        for (i = 0; i < FREQ_DEPTH; i = i + 1)
            freq_mem[i] = 32'd0;

        // DC and out-of-range bins must not win.  A smaller in-range spur and
        // a single dominant peak make the comparison unambiguous.
        freq_mem[0]             = 32'hffff_ffff;
        freq_mem[5]             = 32'hffff_fffe;
        freq_mem[SEARCH_START]  = 32'd200;
        freq_mem[PEAK_INDEX]    = PEAK_MAGNITUDE;
        freq_mem[SEARCH_END]    = 32'd300;
        freq_mem[4001]           = 32'hffff_ffff;

        repeat (4) @(negedge calc_clk);
        rst = 1'b0;
        repeat (4) @(negedge calc_clk);
        frame_done_toggle = 1'b1;

        for (timeout_cycles = 0; timeout_cycles < 30000;
             timeout_cycles = timeout_cycles + 1) begin
            @(negedge calc_clk);
            if (test_done)
                timeout_cycles = 30000;
        end

        assert (test_done)
            else $fatal(1, "Timeout: Peak_Search did not produce a result");
        assert (read_count == SEARCH_END-SEARCH_START+1)
            else $fatal(1, "Expected %0d peak reads, got %0d",
                        SEARCH_END-SEARCH_START+1, read_count);
        assert (result_count == 1)
            else $fatal(1, "Expected one peak result, got %0d", result_count);

        $display("PASS: tb_peak_search scanned %0d bins; index=%0d, f1=%0d Hz, amp=%0d.",
                 read_count, max_index, f1_hz, amp_f1);
        $finish;
    end

endmodule
