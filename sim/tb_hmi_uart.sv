`timescale 1ns/1ps

//==============================================================================
// tb_hmi_uart
//------------------------------------------------------------------------------
// HMI/UART 行为仿真：
//   * 直接验证 BIN2BCD 的 Double-Dabble 转换；
//   * 用一个缩小后的时钟比例验证 UART 8-N-1 波形；
//   * 检查四条 tX.txt="..." 命令的字节序列和 0xff 结束符；
//   * 检查 8 个 add 1,0,Y 命令的前缀、十进制 Y 字节和结束符；
//   * 验证 HMI 的同步时域 BRAM 读取不会越界，并最终产生 waveform_done。
//
// HMI 实例的 CLK_FREQ_HZ 使用 1.152 MHz、BAUD_RATE 使用 115200，因此
// 每个 UART bit 为 10 个算法时钟。这样保持相同的 115200 波特率协议，
// 同时把仿真长度从实际 100 MHz 的约 6 M 个时钟压缩到可快速回归的范围。
//==============================================================================
module tb_hmi_uart;

    localparam integer CLK_FREQ_HZ = 1_152_000;
    localparam integer BAUD_RATE   = 115_200;
    localparam integer CLKS_PER_BIT = 10;
    localparam integer FRAME_LENGTH = 64;
    localparam integer TIME_ADDR_WIDTH = 6;
    localparam integer WAVE_POINTS = 8;

    reg clk;
    reg rst;

    // Direct BIN2BCD check.
    reg        bcd_start;
    reg [31:0] bcd_binary_in;
    wire [39:0] bcd_out;
    wire       bcd_busy;
    wire       bcd_done;

    // HMI inputs/outputs.
    reg        time_result_valid;
    reg [16:0] vpp_in;
    reg [15:0] vrms_in;
    reg        peak_result_valid;
    reg [11:0] f1_index_in;
    reg [31:0] f1_hz_in;
    reg [31:0] amp_f1_in;
    reg        display_three_cycles;
    wire       time_rd_en;
    wire [TIME_ADDR_WIDTH-1:0] time_rd_addr;
    reg signed [15:0] time_rd_data;
    wire       uart_tx;
    wire       hmi_busy;
    wire       waveform_done;
    wire       frame_release;
    wire       measurement_valid;
    wire [4:0] state_debug;

    reg signed [15:0] time_mem [0:FRAME_LENGTH-1];

    // Captured UART bytes.
    reg [7:0] rx_bytes [0:1023];
    integer rx_count;
    integer rx_bit;
    integer rx_index;
    reg [7:0] rx_byte;

    integer i;
    integer timeout_cycles;
    reg     waveform_seen;
    integer measurement_valid_count;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    BIN2BCD #(
        .INPUT_WIDTH(32),
        .DIGITS     (10)
    ) dut_bin2bcd (
        .clk      (clk),
        .rst      (rst),
        .start    (bcd_start),
        .binary_in(bcd_binary_in),
        .bcd_out  (bcd_out),
        .busy     (bcd_busy),
        .done     (bcd_done)
    );

    HMI_UART_Ctrl #(
        .CLK_FREQ_HZ    (CLK_FREQ_HZ),
        .BAUD_RATE      (BAUD_RATE),
        .FRAME_LENGTH   (FRAME_LENGTH),
        .TIME_ADDR_WIDTH(TIME_ADDR_WIDTH),
        .WAVE_POINTS    (WAVE_POINTS),
        .DISPLAY_CYCLES (1)
    ) dut_hmi (
        .clk                    (clk),
        .rst                    (rst),
        .time_result_valid      (time_result_valid),
        .vpp_in                 (vpp_in),
        .vrms_in                (vrms_in),
        .peak_result_valid      (peak_result_valid),
        .f1_index_in            (f1_index_in),
        .f1_hz_in               (f1_hz_in),
        .amp_f1_in              (amp_f1_in),
        .display_three_cycles   (display_three_cycles),
        .time_rd_en             (time_rd_en),
        .time_rd_addr           (time_rd_addr),
        .time_rd_data           (time_rd_data),
        .uart_tx                (uart_tx),
        .busy                   (hmi_busy),
        .waveform_done          (waveform_done),
        .frame_release          (frame_release),
        .measurement_valid      (measurement_valid),
        .state_debug            (state_debug)
    );

    always @(posedge clk) begin
        if (!rst && measurement_valid)
            measurement_valid_count = measurement_valid_count + 1;
    end

    // Synchronous BRAM model for the HMI read port.
    always @(posedge clk) begin
        if (time_rd_en) begin
            assert (time_rd_addr < FRAME_LENGTH)
                else $fatal(1, "HMI time BRAM address out of range: %0d",
                            time_rd_addr);
            time_rd_data <= time_mem[time_rd_addr];
        end
    end

    // A simple UART receiver samples in the middle of each bit.  The receiver
    // runs in the same clock domain and therefore also checks that the start,
    // data and stop bits remain at the expected duration.
    always @(negedge uart_tx) begin
        if (!rst) begin
            repeat (CLKS_PER_BIT/2) @(posedge clk);
            assert (uart_tx === 1'b0)
                else $fatal(1, "UART start bit was not low at its midpoint");

            rx_byte = 8'd0;
            for (rx_bit = 0; rx_bit < 8; rx_bit = rx_bit + 1) begin
                repeat (CLKS_PER_BIT) @(posedge clk);
                rx_byte[rx_bit] = uart_tx;
            end

            repeat (CLKS_PER_BIT) @(posedge clk);
            assert (uart_tx === 1'b1)
                else $fatal(1, "UART stop bit was not high");
            rx_bytes[rx_count] = rx_byte;
            rx_count = rx_count + 1;
        end
    end

    task automatic check_bcd;
        input [31:0] value;
        input [39:0] expected;
        begin
            @(negedge clk);
            bcd_binary_in = value;
            bcd_start     = 1'b1;
            @(negedge clk);
            bcd_start     = 1'b0;
            wait (bcd_done);
            assert (bcd_out == expected)
                else $fatal(1, "BIN2BCD mismatch for %0d: got %h expected %h",
                            value, bcd_out, expected);
            @(negedge clk);
        end
    endtask

    task automatic check_rx_byte;
        input integer index;
        input [7:0] expected;
        begin
            assert (rx_bytes[index] == expected)
                else $fatal(1, "UART byte[%0d] mismatch: got 0x%02h expected 0x%02h",
                            index, rx_bytes[index], expected);
        end
    endtask

    integer wave_cursor;
    integer wave_digit_start;
    integer digit_count;

    initial begin
        bcd_start            = 1'b0;
        bcd_binary_in       = 32'd0;
        time_result_valid   = 1'b0;
        peak_result_valid   = 1'b0;
        vpp_in              = 17'd1000;
        vrms_in             = 16'd250;
        f1_index_in         = 12'd4;
        f1_hz_in             = 32'd2000;
        amp_f1_in           = 32'd12345;
        display_three_cycles= 1'b0;
        time_rd_data        = 16'sd0;
        rx_count            = 0;
        waveform_seen       = 1'b0;
        measurement_valid_count = 0;
        rst                 = 1'b1;

        for (i = 0; i < FRAME_LENGTH; i = i + 1)
            time_mem[i] = ((i % 8) - 4) * 100;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Standalone Double-Dabble vectors, including the 32-bit maximum.
        check_bcd(32'd0,          40'h0000000000);
        check_bcd(32'd250,        40'h0000000250);
        check_bcd(32'd12345,      40'h0000012345);
        check_bcd(32'hffff_ffff,  40'h4294967295);

        // Present one complete measurement packet to HMI.
        repeat (4) @(negedge clk);
        time_result_valid = 1'b1;
        peak_result_valid = 1'b1;
        @(negedge clk);
        time_result_valid = 1'b0;
        peak_result_valid = 1'b0;

        for (timeout_cycles = 0; timeout_cycles < 500000;
             timeout_cycles = timeout_cycles + 1) begin
            @(negedge clk);
            if (waveform_done) begin
                waveform_seen = 1'b1;
                timeout_cycles = 500000;
            end
        end

        assert (waveform_seen)
            else $fatal(1, "Timeout: HMI waveform_done was not asserted");
        assert (measurement_valid_count == 1)
            else $fatal(1, "Expected one measurement_valid pulse, got %0d",
                        measurement_valid_count);
        assert (frame_release === 1'b1)
            else $fatal(1, "HMI did not hold frame_release after packet completion");

        // waveform_done is raised when the final terminator is accepted by
        // UART_Tx; allow that last byte to finish on the serial pin before
        // decoding the complete stream.
        repeat (CLKS_PER_BIT * 12) @(posedge clk);

        // The four text commands are:
        // t0.txt="1000"\xff\xff\xff
        // t1.txt="250" \xff\xff\xff
        // t2.txt="2000"\xff\xff\xff
        // t3.txt="12345"\xff\xff\xff
        // Their combined length is 64 bytes.
        assert (rx_count >= 64)
            else $fatal(1, "UART stream ended before text commands, bytes=%0d",
                        rx_count);

        check_rx_byte(0,  "t"); check_rx_byte(1,  "0");
        check_rx_byte(2,  "."); check_rx_byte(3,  "t");
        check_rx_byte(4,  "x"); check_rx_byte(5,  "t");
        check_rx_byte(6,  "="); check_rx_byte(7,  "\"");
        check_rx_byte(8,  "1"); check_rx_byte(9,  "0");
        check_rx_byte(10, "0"); check_rx_byte(11, "0");
        check_rx_byte(12, "\""); check_rx_byte(13, 8'hff);
        check_rx_byte(14, 8'hff); check_rx_byte(15, 8'hff);

        check_rx_byte(16, "t"); check_rx_byte(17, "1");
        check_rx_byte(18, "."); check_rx_byte(19, "t");
        check_rx_byte(20, "x"); check_rx_byte(21, "t");
        check_rx_byte(22, "="); check_rx_byte(23, "\"");
        check_rx_byte(24, "2"); check_rx_byte(25, "5");
        check_rx_byte(26, "0"); check_rx_byte(27, "\"");
        check_rx_byte(28, 8'hff); check_rx_byte(29, 8'hff);
        check_rx_byte(30, 8'hff);

        check_rx_byte(31, "t"); check_rx_byte(32, "2");
        check_rx_byte(33, "."); check_rx_byte(34, "t");
        check_rx_byte(35, "x"); check_rx_byte(36, "t");
        check_rx_byte(37, "="); check_rx_byte(38, "\"");
        check_rx_byte(39, "2"); check_rx_byte(40, "0");
        check_rx_byte(41, "0"); check_rx_byte(42, "0");
        check_rx_byte(43, "\""); check_rx_byte(44, 8'hff);
        check_rx_byte(45, 8'hff); check_rx_byte(46, 8'hff);

        check_rx_byte(47, "t"); check_rx_byte(48, "3");
        check_rx_byte(49, "."); check_rx_byte(50, "t");
        check_rx_byte(51, "x"); check_rx_byte(52, "t");
        check_rx_byte(53, "="); check_rx_byte(54, "\"");
        check_rx_byte(55, "1"); check_rx_byte(56, "2");
        check_rx_byte(57, "3"); check_rx_byte(58, "4");
        check_rx_byte(59, "5"); check_rx_byte(60, "\"");
        check_rx_byte(61, 8'hff); check_rx_byte(62, 8'hff);
        check_rx_byte(63, 8'hff);

        // Waveform portion: exactly WAVE_POINTS commands, each with a valid
        // add prefix, 1..3 ASCII decimal Y digits, and three terminators.
        wave_cursor = 64;
        for (i = 0; i < WAVE_POINTS; i = i + 1) begin
            check_rx_byte(wave_cursor + 0, "a");
            check_rx_byte(wave_cursor + 1, "d");
            check_rx_byte(wave_cursor + 2, "d");
            check_rx_byte(wave_cursor + 3, " ");
            check_rx_byte(wave_cursor + 4, "1");
            check_rx_byte(wave_cursor + 5, ",");
            check_rx_byte(wave_cursor + 6, "0");
            check_rx_byte(wave_cursor + 7, ",");
            wave_cursor = wave_cursor + 8;
            wave_digit_start = wave_cursor;
            digit_count = 0;
            while (rx_bytes[wave_cursor] != 8'hff) begin
                assert ((rx_bytes[wave_cursor] >= "0") &&
                        (rx_bytes[wave_cursor] <= "9"))
                    else $fatal(1, "Invalid waveform Y byte 0x%02h",
                                rx_bytes[wave_cursor]);
                digit_count = digit_count + 1;
                wave_cursor = wave_cursor + 1;
            end
            assert ((digit_count >= 1) && (digit_count <= 3))
                else $fatal(1, "Invalid waveform Y digit count %0d", digit_count);

            // With FRAME_LENGTH=64, f1_index=4 and WAVE_POINTS=8, the
            // integer sample addresses are 0,2,4,6,8,10,12,15.  These checks
            // exercise both the parameterized 7-way address divider and the
            // signed absolute-value path for the negative samples.
            if (i == 0) begin
                assert (digit_count == 3) else $fatal(1, "Y[0] digit count");
                check_rx_byte(wave_digit_start + 0, "2");
                check_rx_byte(wave_digit_start + 1, "3");
                check_rx_byte(wave_digit_start + 2, "0");
            end
            else if (i == 1) begin
                assert (digit_count == 3) else $fatal(1, "Y[1] digit count");
                check_rx_byte(wave_digit_start + 0, "1");
                check_rx_byte(wave_digit_start + 1, "7");
                check_rx_byte(wave_digit_start + 2, "9");
            end
            else if (i == 2) begin
                assert (digit_count == 3) else $fatal(1, "Y[2] digit count");
                check_rx_byte(wave_digit_start + 0, "1");
                check_rx_byte(wave_digit_start + 1, "2");
                check_rx_byte(wave_digit_start + 2, "8");
            end
            else if (i == 3) begin
                assert (digit_count == 2) else $fatal(1, "Y[3] digit count");
                check_rx_byte(wave_digit_start + 0, "7");
                check_rx_byte(wave_digit_start + 1, "7");
            end
            check_rx_byte(wave_cursor,     8'hff);
            check_rx_byte(wave_cursor + 1, 8'hff);
            check_rx_byte(wave_cursor + 2, 8'hff);
            wave_cursor = wave_cursor + 3;
        end

        assert (rx_count == wave_cursor)
            else $fatal(1, "Unexpected UART bytes: got %0d expected %0d",
                        rx_count, wave_cursor);

        $display("PASS: tb_hmi_uart decoded %0d UART bytes and all BIN2BCD/HMI checks.",
                 rx_count);
        $finish;
    end

endmodule
