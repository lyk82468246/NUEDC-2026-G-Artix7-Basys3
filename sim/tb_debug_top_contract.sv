`timescale 1ns/1ps
// Elaboration only: real RTL, unisim primitives, black-box DSP/VIO/MMCM ports.
// No ADC/FFT/ILA behavioral correctness is claimed by this test.
module tb_debug_top_contract;
    G_FPGA_Top #(.ENABLE_RUNTIME_CALIBRATION(0)) plain(.sys_clk(1'b0),.sys_rst_n(1'b1),
        .key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),.sw(16'd2),.adc_data_in(12'd0));
    G_FPGA_Top #(.ENABLE_RUNTIME_CALIBRATION(1)) vio(.sys_clk(1'b0),.sys_rst_n(1'b1),
        .key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),.sw(16'd2),.adc_data_in(12'd0));
    G_FPGA_Top #(.ENABLE_DISPLAY(0)) legacy(.sys_clk(1'b0),.sys_rst_n(1'b1),
        .key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),.sw(16'd2),.adc_data_in(12'd0));
    initial begin
        #1;
        assert($bits(vio.u_ila_system.probe1)==17 && $bits(vio.u_ila_system.probe3)==32 &&
               $bits(vio.u_ila_system.probe10)==96 && $bits(vio.u_ila_system.probe11)==2 &&
               $bits(vio.u_ila_system.probe12)==32 && $bits(vio.u_ila_system.probe13)==32 &&
               $bits(vio.u_ila_system.probe14)==8) else $fatal(1,"ILA contract widths");
        assert(plain.calibration_epoch===32'd0 && plain.calibration_enabled===1'b0)
            else $fatal(1,"Non-VIO branch not driven");
        assert(plain.display_vpp_gain===0 && plain.display_rms_gain===0 && plain.display_fft_gain===0)
            else $fatal(1,"Non-VIO display gains not disabled");
        // Real subsystem wiring: a pending Run_Controller arm may NOT bypass
        // the display replay's BRAM ownership. DSP IP remains a black box.
        force plain.capture_enable=1;force plain.hmi_busy=1;
        #1;assert(plain.u_capture_calc_subsystem.u_afe_capture.capture_enable===0)
            else $fatal(1,"Display replay allowed ADC overwrite");
        force plain.hmi_busy=0;
        #1;assert(plain.u_capture_calc_subsystem.u_afe_capture.capture_enable===1)
            else $fatal(1,"Arm did not resume after display");
        release plain.capture_enable;release plain.hmi_busy;
        $display("PASS: top port contract VIO on/off, legacy/new HMI, real capture permit blocked during replay (black-box DSP IP)");$finish;
    end
endmodule
