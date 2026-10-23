`timescale 1ns/1ps
module tb_board_panel;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [4:0] switches=0;
    wire [4:0] stable;
    wire ready;
    Switch_Filter #(.STABLE_CYCLES(4)) filter(.clk(clk),.rst(rst),.async_in(switches),.stable_out(stable),.ready(ready));
    reg button=0; wire press;
    Button_Debounce #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(3)) key(
        .clk(clk),.rst(rst),.button_in(button),.button_state(),.button_pulse(press));
    integer presses=0;
    always @(posedge clk) if(!rst && press) presses=presses+1;
    reg valid=0; reg [31:0] value=1000; reg [3:0] points=2;
    wire [6:0] seg; wire [3:0] an; wire dp;
    SevenSeg_Scan #(.SCAN_CYCLES(8)) scan(.clk(clk),.rst(rst),.value(value),
        .valid(valid),.decimal_points(points),.seg(seg),.an(an),.dp(dp));
    reg measurement=0;
    reg [31:0] frequency=100000;
    wire [15:0] leds;
    Board_Status_Display #(.CLK_HZ(1000),.SCAN_CYCLES(8)) status_display(
        .clk(clk),.rst(rst),.locked(1'b1),.measurement_valid(measurement),.fresh(1'b1),
        .capture_busy(1'b0),.algorithm_busy(1'b0),.hmi_busy(1'b0),
        .mode(2'd2),.view(2'd0),.single_mode(1'b1),.three_cycles(1'b1),
        .error_code(4'h2),.frequency_hz(frequency),.magnitude_raw(32'd100),
        .vpp_raw(17'd200),.rms_raw(16'd70),.led(leds),.seg(),.an(),.dp());
    task tick; begin @(negedge clk); end endtask
    integer i;
    initial begin
        repeat(5) tick(); rst=0;
        repeat(12) tick(); assert(ready && stable==0) else $fatal(1,"Filter boot");
        switches=5'b11111; tick(); switches=0; repeat(5) tick();
        assert(stable==0) else $fatal(1,"Switch glitch accepted");
        for(i=0;i<32;i=i+1) begin
            switches=i; repeat(12) tick();
            assert(stable==i) else $fatal(1,"Switch vector settling");
        end
        button=1;tick();button=0;repeat(6) tick();
        assert(presses==0) else $fatal(1,"Button glitch accepted");
        button=1;repeat(20) tick();assert(presses==1) else $fatal(1,"Held button repeated");
        button=0;repeat(12) tick();button=1;repeat(12) tick();
        assert(presses==2) else $fatal(1,"Button did not rearm");
        valid=1; repeat(200) tick();
        repeat(64) begin
            tick(); assert($onehot0(~an)) else $fatal(1,"Multiple digits on");
            if(an!=15) begin
                if(an==4'b0111) assert(seg==7'b1111001) else $fatal(1,"Thousands digit");
                else assert(seg==7'b1000000) else $fatal(1,"Zero digit");
                assert(dp==((an==4'b1101)?0:1)) else $fatal(1,"Decimal point");
            end
        end
        value=65535;repeat(200) tick();
        repeat(32) begin tick();if(an==4'b1011) assert(seg==7'b0001110) else $fatal(1,"Overflow not OFLO");end
        valid=0;repeat(200) tick();
        repeat(32) begin tick();if(an!=15) assert(seg==7'b0111111 && dp) else $fatal(1,"Stale not dashes");end
        // Full-range /100 reference and new-result restart. Serial divider
        // latency must not expose a partly calculated quotient as valid.
        for(i=0;i<8;i=i+1) begin
            case(i)
                0:frequency=0;1:frequency=99;2:frequency=100;3:frequency=100000;
                4:frequency=500000;5:frequency=32'hffffffff;
                default:frequency=$urandom;
            endcase
            measurement=1;tick();measurement=0;repeat(32) tick();
            assert(status_display.f_display==frequency/100 && status_display.freq_bits==0)
                else $fatal(1,"Serial frequency conversion mismatch for %0d",frequency);
        end
        frequency=100000;measurement=1;tick();measurement=0;repeat(4) tick();
        frequency=200000;measurement=1;tick();measurement=0;repeat(32) tick();
        assert(status_display.f_display==2000) else $fatal(1,"Divider restart used stale frame");
        assert(leds[15:8]==8'h2e && leds[7] && leds[6] && leds[0])
            else $fatal(1,"Status LED bit mapping");
        $display("PASS: tb_board_panel switch32, bounce, active-low scan, kHz point, OFLO and invalid");
        $finish;
    end
endmodule
