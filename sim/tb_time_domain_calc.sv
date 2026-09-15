`timescale 1ns/1ps

//==============================================================================
// tb_time_domain_calc
//------------------------------------------------------------------------------
// 定向行为仿真：Time_Domain_Calc + 工程生成的 CORDIC Square Root 行为网表。
//
// 覆盖内容：
//   * 8192 点同步 BRAM 读时序；
//   * 有符号样本的 max/min、Vpp 和平方累加；
//   * mean_square = sum >> 13；
//   * CORDIC RMS 结果；
//   * BRAM 地址边界、顺序、访问次数和 result_valid 单周期断言。
//
// 该 testbench 不修改 DUT 内部寄存器，只通过公开端口和同步 BRAM 模型
// 检查模块行为，因此可以作为后续回归测试的基础。
//==============================================================================
module tb_time_domain_calc;

    localparam integer FRAME_LENGTH = 8192;
    localparam integer DATA_WIDTH   = 16;
    localparam integer ADDR_WIDTH   = 13;

    // Expected values for sample_value = (((index % 17) - 8) * 1000).
    // They are kept as explicit constants because some XSim versions perform
    // unsized mixed-width arithmetic differently for a 64-bit packed reg.
    localparam integer EXPECTED_VPP          = 16000;
    localparam [31:0] EXPECTED_MEAN_SQUARE  = 32'd23992065;
    localparam integer EXPECTED_RMS          = 4898;

    reg                         calc_clk;
    reg                         rst;
    reg                         frame_done_toggle;
    wire [ADDR_WIDTH-1:0]       bram_rd_addr;
    wire                        bram_rd_en;
    reg  signed [DATA_WIDTH-1:0] bram_rd_data;
    wire [DATA_WIDTH:0]         vpp_out;
    wire [DATA_WIDTH-1:0]       vrms_out;
    wire [31:0]                 mean_square_out;
    wire                        result_valid;
    wire                        busy;

    reg signed [DATA_WIDTH-1:0] sample_mem [0:FRAME_LENGTH-1];

    integer i;
    integer sample_value;
    integer expected_max;
    integer expected_min;
    integer expected_vpp;
    integer expected_rms;
    reg [63:0] expected_sum;
    reg [31:0] expected_mean_square;
    integer request_count;
    integer expected_request_addr;
    integer result_count;
    integer busy_cycles;
    integer timeout_cycles;
    reg previous_result_valid;
    reg test_done;

    // 100 MHz algorithm clock.
    initial calc_clk = 1'b0;
    always #5 calc_clk = ~calc_clk;

    Time_Domain_Calc #(
        .DATA_WIDTH  (DATA_WIDTH),
        .FRAME_LENGTH(FRAME_LENGTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .SUM_WIDTH   (44)
    ) dut (
        .calc_clk         (calc_clk),
        .rst              (rst),
        .frame_done_toggle(frame_done_toggle),
        .bram_rd_addr     (bram_rd_addr),
        .bram_rd_en       (bram_rd_en),
        .bram_rd_data     (bram_rd_data),
        .vpp_out          (vpp_out),
        .vrms_out         (vrms_out),
        .mean_square_out  (mean_square_out),
        .result_valid     (result_valid),
        .busy             (busy)
    );

    // Synchronous-read BRAM model.  The DUT requests address N in one clock
    // cycle and consumes bram_rd_data in the following PROCESS state.
    always @(posedge calc_clk) begin
        if (bram_rd_en) begin
            assert (bram_rd_addr < FRAME_LENGTH)
                else $fatal(1, "BRAM address out of range: %0d", bram_rd_addr);
            bram_rd_data <= sample_mem[bram_rd_addr];
        end
    end

    // Scoreboard and protocol assertions.  Immediate assertions are used here
    // so the test can run with Vivado XSim in SystemVerilog mode without a
    // separate assertion package.
    always @(posedge calc_clk) begin
        if (rst) begin
            request_count       <= 0;
            expected_request_addr <= 0;
            result_count        <= 0;
            busy_cycles         <= 0;
            previous_result_valid <= 1'b0;
        end
        else begin
            if (bram_rd_en) begin
                assert (bram_rd_addr == expected_request_addr)
                    else $fatal(1,
                        "BRAM address sequence error: got %0d, expected %0d",
                        bram_rd_addr, expected_request_addr);
                request_count <= request_count + 1;
                if (expected_request_addr == FRAME_LENGTH-1)
                    expected_request_addr <= 0;
                else
                    expected_request_addr <= expected_request_addr + 1;
            end

            if (busy)
                busy_cycles <= busy_cycles + 1;

            // result_valid is specified as a one-cycle pulse.
            assert (!(previous_result_valid && result_valid))
                else $fatal(1, "result_valid lasted more than one cycle");
            previous_result_valid <= result_valid;

            if (result_valid) begin
                result_count <= result_count + 1;
                assert (request_count == FRAME_LENGTH)
                    else $fatal(1, "Result arrived after %0d BRAM reads", request_count);
                assert (vpp_out == expected_vpp)
                    else $fatal(1, "Vpp mismatch: got %0d expected %0d",
                                vpp_out, expected_vpp);
                assert (mean_square_out == expected_mean_square[31:0])
                    else $fatal(1, "Mean-square mismatch: got %0d expected %0d",
                                mean_square_out, expected_mean_square);
                // The generated CORDIC is an integer square-root.  Allow one
                // LSB for the configured rounding mode.
                assert ((vrms_out >= expected_rms-1) &&
                        (vrms_out <= expected_rms+1))
                    else $fatal(1, "Vrms mismatch: got %0d expected about %0d",
                                vrms_out, expected_rms);

                $display("PASS: Vpp=%0d, mean_square=%0d, Vrms=%0d",
                         vpp_out, mean_square_out, vrms_out);
                test_done <= 1'b1;
            end
        end
    end

    initial begin
        expected_max        = -32768;
        expected_min        =  32767;
        expected_sum        = 0;
        expected_vpp        = 0;
        expected_rms        = 0;
        expected_mean_square = 0;
        request_count       = 0;
        expected_request_addr = 0;
        result_count        = 0;
        busy_cycles         = 0;
        previous_result_valid = 1'b0;
        test_done           = 1'b0;
        bram_rd_data        = '0;
        frame_done_toggle   = 1'b0;
        rst                 = 1'b1;

        // Deterministic signed pattern with negative, zero and positive
        // samples.  The period 17 pattern also catches accidental DC/max-min
        // initialization bugs better than a symmetric two-value waveform.
        for (i = 0; i < FRAME_LENGTH; i = i + 1) begin
            sample_value = ((i % 17) - 8) * 1000;
            sample_mem[i] = sample_value;
            if (sample_value > expected_max)
                expected_max = sample_value;
            if (sample_value < expected_min)
                expected_min = sample_value;
            expected_sum = expected_sum + sample_value * sample_value;
        end

        // Use independently calculated reference constants for the checks.
        // The loop above still initializes the complete signed stimulus set;
        // these values avoid simulator-dependent expression sizing in the
        // scoreboard itself.
        expected_vpp         = EXPECTED_VPP;
        expected_mean_square = EXPECTED_MEAN_SQUARE;
        expected_rms         = EXPECTED_RMS;

        // Release reset and create one frame-done toggle event.
        repeat (4) @(negedge calc_clk);
        rst = 1'b0;
        repeat (4) @(negedge calc_clk);
        frame_done_toggle = 1'b1;

        // The longest normal path is well below this bound; a timeout catches
        // a deadlocked CORDIC or FSM without hanging batch simulation.
        for (timeout_cycles = 0; timeout_cycles < 50000; timeout_cycles = timeout_cycles + 1) begin
            @(negedge calc_clk);
            if (test_done)
                timeout_cycles = 50000;
        end

        assert (test_done)
            else $fatal(1, "Timeout: Time_Domain_Calc did not produce a result");
        assert (result_count == 1)
            else $fatal(1, "Expected exactly one result, got %0d", result_count);
        assert (request_count == FRAME_LENGTH)
            else $fatal(1, "Expected %0d BRAM reads, got %0d",
                        FRAME_LENGTH, request_count);
        assert (busy_cycles > FRAME_LENGTH)
            else $fatal(1, "busy did not cover the frame calculation");

        $display("PASS: tb_time_domain_calc completed with %0d BRAM reads.",
                 request_count);
        $finish;
    end

endmodule
