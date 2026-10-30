`timescale 1ns / 1ps

//==============================================================================
// G_FPGA_Top
//------------------------------------------------------------------------------
// Absolute Basys 3 top level for the periodic-signal measurement system.
//
// External resources:
//   sys_clk       : 100 MHz board oscillator, W5
//   sys_rst_n     : mapped to BtnC/U18.  Basys 3 BtnC is electrically active
//                   high, so BUTTON_ACTIVE_HIGH defaults to 1.  The port name
//                   is kept as requested; set BUTTON_ACTIVE_HIGH=0 only when
//                   an external active-low reset source is wired to this pin.
//   key_cycle     : BtnU/T18, toggles one-period/three-period HMI display mode
//   adc_clk_out   : ODDR-forwarded 4.096045 MHz clock, JB1/A14
//   adc_data_in   : AD9226 parallel bus on JB2..JB10 and JC1..JC4/JC7
//   uart_tx       : UART display TX on JA1/J1
//==============================================================================
module G_FPGA_Top #(
    parameter integer BUTTON_ACTIVE_HIGH = 1,
    parameter integer KEY_DEBOUNCE_MS = 20,
    parameter integer SWITCH_STABLE_CYCLES = 2_000_000,
    // PLACEHOLDER: portrait 240x320 HMI. Confirm actual plot width before use.
    parameter integer WAVE_POINTS = 240,
    parameter integer ENABLE_DISPLAY=1,
    parameter integer DISPLAY_HEIGHT=160,DISPLAY_INVERT_Y=0,DISPLAY_STATUS=0,
    parameter integer SCREEN_FFT_VIEW=3,
    parameter integer DISPLAY_STARTUP_CYCLES=50_000_000,DISPLAY_PAGE_REFRESH=0,
    parameter integer DISPLAY_COMMAND_GAP=10000,DISPLAY_PAGE_GAP=5_000_000,
    parameter integer DISPLAY_CURVE_ID=1,DISPLAY_CHANNEL=0,
    parameter integer DISPLAY_REFRESH_GUARD=1,DISPLAY_WAVE_ALIGNMENT=1,DISPLAY_FFT_REVERSE_X=1,
    // Verified generator-HIGHZ reference bank, 2026-10-23/24. Q16.16 uV/raw;
    // NOT independent absolute input calibration. Reset epoch is 0; VIO edits
    // increment it normally. Set DEFAULT_CALIBRATION_ENABLED=0 to opt out.
    parameter integer DEFAULT_CALIBRATION_ENABLED=1,
    parameter [31:0] DEFAULT_VPP_GAIN=32'd3623460,
    parameter [31:0] DEFAULT_RMS_GAIN=32'd3701829,
    parameter [31:0] DEFAULT_FFT_GAIN=32'd4194,
    // Raw RMS units, not mV. Keep production default until path calibration.
    // Direct-ADC bench override 16 is supported by measured OFF=3..4 and
    // 50mVpp/100kHz=28. It does NOT reject the noisy external-filter path.
    parameter integer MIN_SIGNAL_RMS = 64,
    // Enable after setup_runtime_calibration.tcl. Feeds the new display's
    // reference-mV bank as well as the diagnostic sidecar; never the DSP path.
    // Disabled => use the static boot bank; raw diagnostics remain unchanged.
    parameter integer ENABLE_RUNTIME_CALIBRATION = 0,
    // P1 diagnostic only: never writes flash and does not apply restored banks.
    // Requires setup_flash_readonly.tcl (VIO + source + pin/timing registration).
    parameter integer ENABLE_FLASH_READONLY_PROBE = 0
)(
    input  wire       sys_clk,
    input  wire       sys_rst_n,
    input  wire       key_cycle,
    input  wire       key_down, key_left, key_right,
    input  wire [15:0] sw,
    input  wire [11:0] adc_data_in,
    output wire       adc_clk_out,
    output wire       uart_tx,
    output wire [15:0] led,
    output wire [6:0] seg,
    output wire [3:0] an,
    output wire       dp,
    output wire       flash_cs_n,flash_mosi,flash_wp_n,flash_hold_n,
    input wire        flash_miso
);

    assign flash_wp_n=1'b1;
    assign flash_hold_n=1'b1;
    generate if(ENABLE_FLASH_READONLY_PROBE)begin:g_flash_readonly
        wire flash_sck,flash_eos,flash_request;
        wire [31:0] flash_status,flash_sequence,flash_saved_epoch;
        wire [23:0] flash_jedec;
        wire [96:0] flash_bank;
        // Configuration INIT values establish POR independently of BtnC.
        reg [7:0] power_settle=8'hff;
        always @(posedge sys_clk)begin
            if(!flash_eos)power_settle<=8'hff;
            else power_settle<={power_settle[6:0],1'b0};
        end
        STARTUPE2 u_flash_startup(.CFGCLK(),.CFGMCLK(),.EOS(flash_eos),.PREQ(),
            .CLK(1'b0),.GSR(1'b0),.GTS(1'b0),.KEYCLEARB(1'b1),.PACK(1'b0),
            .USRCCLKO(flash_sck),.USRCCLKTS(1'b0),.USRDONEO(1'b1),.USRDONETS(1'b1));
        Flash_Readonly_Probe u_probe(.clk(sys_clk),.por(|power_settle),.request_toggle(flash_request),
            .cs_n(flash_cs_n),.sck(flash_sck),.mosi(flash_mosi),.miso(flash_miso),
            .status(flash_status),.jedec_id(flash_jedec),.record_sequence(flash_sequence),
            .saved_epoch(flash_saved_epoch),.bank(flash_bank));
        vio_flash_calibration u_vio_flash_calibration(.clk(sys_clk),.probe_out0(flash_request),
            .probe_in0(flash_status),.probe_in1(flash_jedec),.probe_in2(flash_sequence),
            .probe_in3(flash_saved_epoch),.probe_in4(flash_bank));
    end else begin:g_no_flash_probe
        assign flash_cs_n=1'b1;assign flash_mosi=1'b1;
    end endgenerate

    wire clk_algo;
    wire clk_adc;
    wire mmcm_locked;

    // Basys 3 pushbuttons have a pull-down and assert high.  The parameter
    // keeps the wrapper usable with an active-low external reset source too.
    wire reset_button_asserted = BUTTON_ACTIVE_HIGH ? sys_rst_n : ~sys_rst_n;
    wire mmcm_reset = reset_button_asserted;
    wire reset_async = reset_button_asserted | ~mmcm_locked;

    MMCM_Top u_mmcm_top (
        .sys_clk_in(sys_clk),
        .reset     (mmcm_reset),
        .clk_algo  (clk_algo),
        .clk_adc   (clk_adc),
        .locked    (mmcm_locked)
    );

    wire rst_algo;
    wire rst_adc;

    Reset_Synchronizer u_reset_sync_algo (
        .clk (clk_algo),
        .arst(reset_async),
        .srst(rst_algo)
    );

    Reset_Synchronizer u_reset_sync_adc (
        .clk (clk_adc),
        .arst(reset_async),
        .srst(rst_adc)
    );

    // The processing subsystem is entirely in the 100 MHz algorithm domain.
    // Its ADC source-capture registers receive the separately synchronized
    // rst_adc below, preventing a reset signal generated by clk_algo from
    // being timed into the BUFR/ADC clock domain.
    wire rst_subsystem = rst_algo;

    // Forward the ADC clock through an ODDR.  D1=1 and D2=0 produce a normal
    // clock waveform while the pad is driven by the dedicated output cell.
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE")
    ) u_adc_clock_oddr (
        .Q (adc_clk_out),
        .C (clk_adc),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R (reset_async),
        .S (1'b0)
    );

    wire [3:0] button_in={key_right,key_left,key_down,key_cycle};
    wire [3:0] button_pulse;
    genvar button_index;
    generate for(button_index=0;button_index<4;button_index=button_index+1) begin:g_keys
        Button_Debounce #(.CLK_FREQ_HZ(100_000_000),.DEBOUNCE_MS(KEY_DEBOUNCE_MS)) u_key(
            .clk(clk_algo),.rst(rst_algo),.button_in(button_in[button_index]),
            .button_state(),.button_pulse(button_pulse[button_index]));
    end endgenerate
    wire [4:0] controls;
    wire controls_ready;
    Switch_Filter #(.WIDTH(5),.STABLE_CYCLES(SWITCH_STABLE_CYCLES)) u_switches(
        .clk(clk_algo),.rst(rst_algo),.async_in({sw[15],sw[3:0]}),
        .stable_out(controls),.ready(controls_ready));
    wire display_three_cycles;
    wire [1:0] mode_active, view_active;
    wire single_active, capture_enable, controller_release;
    wire capture_start, packet_finished, acquisition_fault, result_fresh;
    wire [31:0] frame_id, latency_cycles;
    wire [3:0] error_code;
    wire [2:0] run_state;

    // Results and debug signals from the complete measurement subsystem.
    wire [16:0] vpp_out;
    wire [15:0] vrms_out;
    wire [31:0] mean_square_out;
    wire        result_valid;
    wire        capture_busy;
    wire        calc_busy;
    wire [11:0] max_index_out;
    wire [31:0] f1_hz_out;
    wire [31:0] amp_f1_out;
    wire        peak_result_valid;
    wire        fft_result_valid;
    wire        fft_busy;
    wire        peak_busy;
    wire        hmi_busy;
    wire        waveform_done;
    wire        frame_valid;
    wire        measurement_valid;
    wire [4:0]  uart_state;
    wire measurement_signal_valid;
    wire [11:0] diagnostic_adc;
    wire [35:0] diagnostic_bins;
    wire [31:0] diagnostic_noise;
    wire [1:0] component_count;
    wire [35:0] component_bins;
    wire [95:0] component_magnitudes;
    wire [31:0] calibration_epoch;
    wire calibration_enabled;
    wire [31:0] display_vpp_gain,display_rms_gain,display_fft_gain;
    wire display_cycles_request;
    wire [1:0] display_view_request;
    // Sticky stage events for the current transaction survive a timeout.
    // Clear at frame START, not frame completion or the next arm attempt.
    reg [4:0] diagnostic_events;
    always @(posedge clk_algo) begin
        if(rst_algo || capture_start) diagnostic_events<=0;
        else diagnostic_events<=diagnostic_events |
            {frame_valid,result_valid,fft_result_valid,peak_result_valid,measurement_valid};
    end
    wire [31:0] diagnostic_status={error_code,run_state,controls,
        capture_enable,controller_release,capture_start,frame_valid,
        result_valid,fft_result_valid,peak_result_valid,measurement_signal_valid,
        capture_busy,calc_busy,fft_busy,peak_busy,hmi_busy,
        packet_finished,acquisition_fault,diagnostic_events};

    Run_Controller u_run_controller(
        .clk(clk_algo),.rst(rst_algo),.controls_ready(controls_ready),
        .mode_switches(controls[3:0]),.single_request(controls[4]),
        .start_pulse(button_pulse[1]),.cycle_pulse(button_pulse[0]),
        .left_pulse(button_pulse[2]),.right_pulse(button_pulse[3]),
        .frame_start(capture_start),.measurement_valid(measurement_valid),
        .packet_finished(packet_finished),.acquisition_fault(acquisition_fault),
        .capture_enable(capture_enable),.frame_release(controller_release),
        .mode_active(mode_active),.single_active(single_active),
        .three_cycles_active(display_three_cycles),.view_active(view_active),
        .display_three_cycles_request(display_cycles_request),.display_view_request(display_view_request),
        .frame_id(frame_id),.result_fresh(result_fresh),.error_code(error_code),
        .latency_cycles(latency_cycles),.state_debug(run_state));

    Board_Status_Display #(.VALIDATE_SIGNAL(1)) u_board_status(
        .clk(clk_algo),.rst(rst_algo),.locked(mmcm_locked),
        .measurement_valid(measurement_valid),.fresh(result_fresh),
        .signal_valid(measurement_signal_valid),
        .capture_busy(capture_busy),.algorithm_busy(calc_busy||fft_busy||peak_busy),
        .hmi_busy(hmi_busy),.mode(mode_active),.view(view_active),
        .single_mode(single_active),.three_cycles(display_three_cycles),
        .error_code(error_code),.frequency_hz(f1_hz_out),.magnitude_raw(amp_f1_out),
        .vpp_raw(vpp_out),.rms_raw(vrms_out),.led(led),.seg(seg),.an(an),.dp(dp));

    Capture_Calc_Subsystem #(.CONTROLLED_CAPTURE(1),.WAVE_POINTS(WAVE_POINTS),
        .ENABLE_DISPLAY(ENABLE_DISPLAY),.DISPLAY_HEIGHT(DISPLAY_HEIGHT),
        .DISPLAY_INVERT_Y(DISPLAY_INVERT_Y),.DISPLAY_STATUS(DISPLAY_STATUS),
        .DISPLAY_STARTUP_CYCLES(DISPLAY_STARTUP_CYCLES),.DISPLAY_PAGE_REFRESH(DISPLAY_PAGE_REFRESH),
        .DISPLAY_FFT_REVERSE_X(DISPLAY_FFT_REVERSE_X),.DISPLAY_REFRESH_GUARD(DISPLAY_REFRESH_GUARD),.DISPLAY_WAVE_ALIGNMENT(DISPLAY_WAVE_ALIGNMENT),
        .DISPLAY_COMMAND_GAP(DISPLAY_COMMAND_GAP),.DISPLAY_PAGE_GAP(DISPLAY_PAGE_GAP),
        .DISPLAY_CURVE_ID(DISPLAY_CURVE_ID),.DISPLAY_CHANNEL(DISPLAY_CHANNEL),
        .MIN_SIGNAL_RMS(MIN_SIGNAL_RMS)) u_capture_calc_subsystem (
        .adc_clk             (clk_adc),
        .calc_clk            (clk_algo),
        .rst                 (rst_subsystem),
        .rst_adc             (rst_adc),
        .adc_data            (adc_data_in),
        .display_three_cycles(display_three_cycles),
        .capture_enable(capture_enable),
        .controller_release(controller_release),
        .mode_active(mode_active),
        .display_page_fft(display_view_request==SCREEN_FFT_VIEW),
        .display_cycles_request(display_cycles_request),.single_mode(single_active),
        .display_frame_id(frame_id),.display_calibration_epoch(calibration_epoch),
        .display_vpp_gain(display_vpp_gain),.display_rms_gain(display_rms_gain),.display_fft_gain(display_fft_gain),
        .display_calibration_valid(calibration_enabled),.display_error_code(error_code),
        .capture_start(capture_start),
        .packet_finished(packet_finished),
        .acquisition_fault(acquisition_fault),
        .signal_valid_out(measurement_signal_valid),
        .diagnostic_adc(diagnostic_adc),.diagnostic_bins(diagnostic_bins),
        .noise_mean_out(diagnostic_noise),
        .component_count_out(component_count),.component_bins_out(component_bins),
        .component_magnitudes_out(component_magnitudes),
        .vpp_out             (vpp_out),
        .vrms_out            (vrms_out),
        .mean_square_out     (mean_square_out),
        .result_valid        (result_valid),
        .capture_busy        (capture_busy),
        .calc_busy           (calc_busy),
        .max_index_out       (max_index_out),
        .f1_hz_out           (f1_hz_out),
        .amp_f1_out          (amp_f1_out),
        .peak_result_valid   (peak_result_valid),
        .fft_result_valid    (fft_result_valid),
        .fft_busy            (fft_busy),
        .peak_busy           (peak_busy),
        .hmi_busy            (hmi_busy),
        .waveform_done       (waveform_done),
        .uart_tx             (uart_tx),
        .frame_valid         (frame_valid),
        .measurement_valid   (measurement_valid),
        .uart_state          (uart_state)
    );

    generate if(ENABLE_RUNTIME_CALIBRATION) begin: g_runtime_calibration
        wire [31:0] staged_vpp,staged_rms,staged_fft;
        wire staged_valid,request,ack,active_valid;
        wire [31:0] epoch,result_epoch,count,active_vpp,active_rms,active_fft;
        wire [31:0] vpp_uv,rms_uv,peak_uv;
        wire valid,overflow,busy,done,overrun;
        wire [7:0] flags={3'd0,overrun,busy,overflow,valid,active_valid};
        assign calibration_epoch=epoch;
        assign calibration_enabled=active_valid;
        assign display_vpp_gain=active_vpp;
        assign display_rms_gain=active_rms;
        assign display_fft_gain=active_fft;
        Runtime_Calibration #(.DEFAULT_ENABLED(DEFAULT_CALIBRATION_ENABLED),
            .DEFAULT_VPP_GAIN(DEFAULT_VPP_GAIN),.DEFAULT_RMS_GAIN(DEFAULT_RMS_GAIN),
            .DEFAULT_FFT_GAIN(DEFAULT_FFT_GAIN)) u_runtime_calibration(
            .clk(clk_algo),.rst(rst_algo),.request_toggle(request),.staging_valid(staged_valid),
            .staging_vpp_gain(staged_vpp),.staging_rms_gain(staged_rms),.staging_fft_gain(staged_fft),
            .sample_valid(measurement_valid),.signal_valid(measurement_signal_valid),
            .vpp_raw(vpp_out),.rms_raw(vrms_out),.fft_raw(amp_f1_out),
            .ack_toggle(ack),.epoch(epoch),.result_epoch(result_epoch),.result_count(count),
            .active_vpp_gain(active_vpp),.active_rms_gain(active_rms),.active_fft_gain(active_fft),
            .active_valid(active_valid),.vpp_uv(vpp_uv),.rms_uv(rms_uv),.peak_uv(peak_uv),
            .valid(valid),.overflow(overflow),.busy(busy),.done(done),.overrun(overrun));
        // VIO reads are live, NOT atomic packets. Host validates count/epoch
        // before/after reading, and rejects busy or stale/overflow results.
        vio_calibration u_vio_calibration(
            .clk(clk_algo),
            .probe_out0(staged_vpp),.probe_out1(staged_rms),.probe_out2(staged_fft),
            .probe_out3(staged_valid),.probe_out4(request),
            .probe_in0(ack),.probe_in1(epoch),.probe_in2(result_epoch),
            .probe_in3(count),.probe_in4(flags),
            .probe_in5(vpp_uv),.probe_in6(rms_uv),.probe_in7(peak_uv),
            .probe_in8(active_vpp),.probe_in9(active_rms),.probe_in10(active_fft));
    end else begin:g_no_runtime_debug
        assign calibration_epoch=32'd0;
        assign calibration_enabled=DEFAULT_CALIBRATION_ENABLED && DEFAULT_VPP_GAIN!=0 &&
            DEFAULT_RMS_GAIN!=0 && DEFAULT_FFT_GAIN!=0;
        assign display_vpp_gain=DEFAULT_VPP_GAIN;
        assign display_rms_gain=DEFAULT_RMS_GAIN;
        assign display_fft_gain=DEFAULT_FFT_GAIN;
    end endgenerate

    wire debug_measurement_valid;
    wire [16:0] debug_vpp;
    wire [15:0] debug_rms;
    wire [31:0] debug_fundamental;
    wire [11:0] debug_fundamental_bin;
    wire [1:0] debug_component_count;
    wire [35:0] debug_component_bins;
    wire [95:0] debug_component_magnitudes;
    wire [31:0] debug_frame_id,debug_calibration_epoch;
    wire [7:0] debug_metadata;
    Measurement_Debug_Snapshot u_debug_snapshot(
        .clk(clk_algo),.rst(rst_algo),.commit(measurement_valid),
        .signal_valid(measurement_signal_valid),.vpp_raw(vpp_out),.rms_raw(vrms_out),
        .fundamental_raw(amp_f1_out),.fundamental_bin(max_index_out),
        .component_count(component_count),.component_bins(component_bins),
        .component_magnitudes(component_magnitudes),.frame_id(frame_id),
        .calibration_epoch(calibration_epoch),.calibration_enabled(calibration_enabled),
        .calibration_present(ENABLE_RUNTIME_CALIBRATION!=0),.mode(mode_active),
        .single_mode(single_active),.three_cycles(display_three_cycles),
        .measurement_valid_out(debug_measurement_valid),.vpp_out(debug_vpp),.rms_out(debug_rms),
        .fundamental_out(debug_fundamental),.fundamental_bin_out(debug_fundamental_bin),
        .component_count_out(debug_component_count),.component_bins_out(debug_component_bins),
        .component_magnitudes_out(debug_component_magnitudes),.frame_id_out(debug_frame_id),
        .calibration_epoch_out(debug_calibration_epoch),.metadata_out(debug_metadata));

    // Schema 2: full 17/32-bit values; qualified slots and metadata latched
    // together. probe0 is delayed to align with the snapshot's NBA update.
    // Original functional consumers keep the undelayed measurement_valid.
    // Probes 5/6/7/9 remain LIVE diagnostics, not atomic packet metadata.
    ila_system u_ila_system (
        .clk   (clk_algo),
        .probe0(debug_measurement_valid),
        .probe1(debug_vpp),
        .probe2(debug_rms),
        .probe3(debug_fundamental),
        .probe4(debug_fundamental_bin),
        .probe5(uart_state),
        .probe6(diagnostic_status),
        .probe7(diagnostic_adc),
        .probe8(debug_component_bins),
        .probe9(diagnostic_noise),
        .probe10(debug_component_magnitudes),
        .probe11(debug_component_count),
        .probe12(debug_frame_id),
        .probe13(debug_calibration_epoch),
        .probe14(debug_metadata)
    );

endmodule
