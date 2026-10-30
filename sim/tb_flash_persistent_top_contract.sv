`timescale 1ns/1ps
module vio_flash_store(input wire clk,output wire probe_out0,output wire [1:0] probe_out1,
    input wire [31:0] probe_in0,input wire [23:0] probe_in1,
    input wire [31:0] probe_in2,probe_in3,input wire [96:0] probe_in4);
    assign probe_out0=0;assign probe_out1=0;
endmodule
module tb_flash_persistent_top_contract;
    reg clk=0,panel=0;always #5 clk=~clk;
    G_FPGA_Top #(.ENABLE_RUNTIME_CALIBRATION(1),.ENABLE_FLASH_PERSISTENCE(1),
        .ENABLE_FLASH_READONLY_PROBE(1),.SWITCH_STABLE_CYCLES(2)) dut(
        .sys_clk(clk),.sys_rst_n(panel),.key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),
        .sw(16'd2),.adc_data_in(12'd2048),.adc_clk_out(),.uart_tx(),.led(),.seg(),.an(),.dp(),
        .flash_cs_n(),.flash_mosi(),.flash_miso(1'b1),.flash_wp_n(),.flash_hold_n());
    initial begin
        force dut.clk_algo=clk;force dut.mmcm_locked=0;
        force dut.g_flash_persistent.store_eos=0;
        #40;force dut.mmcm_locked=1;force dut.g_flash_persistent.store_eos=1;
        #300;
        assert(!dut.store_ready && dut.u_run_controller.state==0)else $fatal(1,"First acquisition not gated by restore");
        panel=1;#40;
        assert(!dut.mmcm_reset && !dut.rst_store)else $fatal(1,"BtnC resets flash clock/POR");
        panel=0;#60;
        force dut.store_ready=1;#30;
        assert(dut.capture_enable && dut.u_capture_calc_subsystem.capture_enable)else $fatal(1,"Restored permit not propagated");
        force dut.store_ready=0;#10;
        assert(!dut.u_capture_calc_subsystem.capture_enable)else $fatal(1,"Reload permit not blocked while ARMED");
        $display("PASS: persistent board top, first-frame/reload gate, BtnC keeps flash clock/POR alive (algorithm IP black boxes)");$finish;
    end
endmodule
