`timescale 1ns/1ps
// Elaboration only: real RTL, unisim primitives, black-box DSP/VIO/MMCM ports.
// No ADC/FFT/ILA behavioral correctness is claimed by this test.
module tb_debug_top_contract;
    G_FPGA_Top #(.ENABLE_RUNTIME_CALIBRATION(0)) plain(.sys_clk(1'b0),.sys_rst_n(1'b1),
        .key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),.sw(16'd2),.adc_data_in(12'd0));
    G_FPGA_Top #(.ENABLE_RUNTIME_CALIBRATION(1)) vio(.sys_clk(1'b0),.sys_rst_n(1'b1),
        .key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),.sw(16'd2),.adc_data_in(12'd0));
    initial begin
        #1;
        assert($bits(vio.u_ila_system.probe1)==17 && $bits(vio.u_ila_system.probe3)==32 &&
               $bits(vio.u_ila_system.probe10)==96 && $bits(vio.u_ila_system.probe11)==2 &&
               $bits(vio.u_ila_system.probe12)==32 && $bits(vio.u_ila_system.probe13)==32 &&
               $bits(vio.u_ila_system.probe14)==8) else $fatal(1,"ILA contract widths");
        assert(plain.calibration_epoch===32'd0 && plain.calibration_enabled===1'b0)
            else $fatal(1,"Non-VIO branch not driven");
        $display("PASS: top port contract elaborated, VIO enabled and disabled (black-box IP)");$finish;
    end
endmodule
