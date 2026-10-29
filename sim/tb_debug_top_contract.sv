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
    G_FPGA_Top #(.DEFAULT_CALIBRATION_ENABLED(0)) uncal(.sys_clk(1'b0),.sys_rst_n(1'b1),
        .key_cycle(1'b0),.key_down(1'b0),.key_left(1'b0),.key_right(1'b0),.sw(16'd2),.adc_data_in(12'd0));
    initial begin
        #1;
        assert($bits(vio.u_ila_system.probe1)==17 && $bits(vio.u_ila_system.probe3)==32 &&
               $bits(vio.u_ila_system.probe10)==96 && $bits(vio.u_ila_system.probe11)==2 &&
               $bits(vio.u_ila_system.probe12)==32 && $bits(vio.u_ila_system.probe13)==32 &&
               $bits(vio.u_ila_system.probe14)==8) else $fatal(1,"ILA contract widths");
        assert(plain.calibration_epoch===32'd0 && plain.calibration_enabled===1'b1 &&
            plain.display_vpp_gain===32'd3623460 && plain.display_rms_gain===32'd3701829 &&
            plain.display_fft_gain===32'd4194) else $fatal(1,"Static boot bank mismatch");
        assert(uncal.calibration_enabled===1'b0)else $fatal(1,"Boot opt-out ignored");
        assert(vio.g_runtime_calibration.u_runtime_calibration.DEFAULT_ENABLED==1 &&
            vio.g_runtime_calibration.u_runtime_calibration.DEFAULT_VPP_GAIN==3623460 &&
            vio.g_runtime_calibration.u_runtime_calibration.DEFAULT_RMS_GAIN==3701829 &&
            vio.g_runtime_calibration.u_runtime_calibration.DEFAULT_FFT_GAIN==4194)
            else $fatal(1,"VIO runtime bank not configured with measured defaults");
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
