`timescale 1ns/1ps
// Simulation-only VIO contract. Generated IP is not modified or substituted in
// the user's implementation. This top checks wiring, not flash pad timing.
module vio_flash_calibration(input wire clk,output wire probe_out0,
    input wire [31:0] probe_in0,input wire [23:0] probe_in1,
    input wire [31:0] probe_in2,probe_in3,input wire [96:0] probe_in4);
    assign probe_out0=1'b0;
endmodule
module tb_flash_top_contract;
    reg sys_clk=0;always #5 sys_clk=~sys_clk;
    wire cs,mosi,wp,hold_n;
    G_FPGA_Top #(.ENABLE_FLASH_READONLY_PROBE(1)) dut(
        .sys_clk(sys_clk),.sys_rst_n(1'b0),.key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),
        .sw(16'd2),.adc_data_in(12'd2048),.adc_clk_out(),.uart_tx(),.led(),.seg(),.an(),.dp(),
        .flash_cs_n(cs),.flash_mosi(mosi),.flash_miso(1'b1),.flash_wp_n(wp),.flash_hold_n(hold_n));
    initial begin
        #3;
        assert(wp && hold_n)else $fatal(1,"HOLD/WP polarity");
        assert(dut.g_flash_readonly.u_probe.u_restore.EXPECTED_JEDEC==24'hc22016)
            else $fatal(1,"Wrong read-only family profile");
        assert($bits(dut.g_flash_readonly.flash_bank)==97 && $bits(dut.g_flash_readonly.flash_jedec)==24)
            else $fatal(1,"VIO width contract");
        $display("PASS: actual board top with read-only flash/VIO/STARTUPE2 wiring (black-box algorithm IP)");
        $finish;
    end
endmodule
