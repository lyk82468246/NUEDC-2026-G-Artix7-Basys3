`timescale 1ns/1ps
// Complete TX-only display transaction owner. No extra frame RAM is allocated.
// The dedicated HMI BRAM replica is read only by the wave renderer. Upstream
// must inhibit capture while busy; frame_release is asserted after UART drain.
// During single-shot HOLD, replay the SAME frozen frame on page/span changes.
// New capture_start invalidates replay immediately. Live gains are sampled only
// at measurement_valid (never after the Amax scan or during HOLD replay).
module Display_HMI #(
    parameter integer CLK_FREQ_HZ=100_000_000,BAUD_RATE=115200,
    parameter integer FRAME_LENGTH=8192,ADDR_WIDTH=13,W=240,H=160,
    parameter integer INVERT_Y=0,ENABLE_STATUS=0,
    parameter integer STARTUP_CYCLES=50_000_000,
    parameter integer COMMAND_GAP_CYCLES=10000,PAGE_GAP_CYCLES=5_000_000,
    // TX-only cannot detect a screen reboot. Periodically reassert ONLY the
    // selected page so a screen power cycle recovers without flipping pages.
    parameter integer PAGE_REFRESH_FRAMES=16,
    // Right-aligned ASCII names; changing layout does not change the FSM.
    parameter [127:0] PAGE_WAVE="wave",PAGE_FFT="fft",
    parameter [127:0] NAME_VPP="tUpp",NAME_RMS="tUrms",
    parameter [127:0] NAME_F1="tF1",NAME_F2="tF2",NAME_F3="tF3",
    parameter [127:0] NAME_A1="tA1",NAME_A2="tA2",NAME_A3="tA3",
    parameter [127:0] NAME_WTOP="tWaveYTop",NAME_WZERO="tWaveY0",NAME_WBOT="tWaveYBot",
    parameter [127:0] NAME_SPAN="tWaveSpan",NAME_WLEFT="tWaveXLeft",NAME_WRIGHT="tWaveXRight",
    parameter [127:0] NAME_FTOP="tFftYTop",NAME_FZERO="tFftY0",
    parameter [127:0] NAME_FLEFT="tFftXLeft",NAME_FRIGHT="tFftXRight",NAME_STATUS="tStatus",
    parameter [31:0] CURVE_ID=1,CHANNEL_ID=0
)(
    input wire clk,rst,capture_start,allow_redraw,
    input wire time_result_valid,peak_result_valid,
    input wire [16:0] vpp_raw,input wire [15:0] rms_raw,
    input wire signal_valid,input wire [1:0] component_count,
    input wire [35:0] component_bins,input wire [95:0] component_magnitudes,
    input wire [31:0] frame_id,calibration_epoch,vpp_gain,rms_gain,fft_gain,
    input wire calibration_valid,
    input wire page_fft_request,three_cycles_request,single_mode,
    input wire [1:0] mode,input wire [3:0] error_code,
    output wire time_rd_en,output wire [ADDR_WIDTH-1:0] time_rd_addr,
    input wire signed [15:0] time_rd_data,
    output wire uart_tx,tx_idle,output wire busy,
    output reg frame_release,measurement_valid,signal_valid_out,waveform_done,
    output wire [4:0] state_debug
);
    localparam IDLE=0,WAVE_START=1,WAVE_AXIS=2,CAL_START=3,CAL_WAIT=4,
        SPEC_START=5,SPEC_AXIS=6,PREPARE_PAGE=7,FIELDS=8,
        MV_START=9,MV_WAIT=10,BCD_START=11,BCD_WAIT=12,
        SEND=13,SEND_WAIT=14,CLEAR=15,PLOT=16,FINISH=18,
        BUILD_NAME=19,BUILD_SUFFIX=20,BUILD_VALUE=21,BUILD_CLOSE=22,
        COMMAND_LENGTH=23,MV_QUEUE=24,BCD_DIGITS=25,BCD_QUEUE=26;
    reg [4:0] state,resume_state;
    // Reset distribution is registered with IDENTICAL latency for the FSM and
    // each child. Avoid driving all command, DSP and divider reset pins from a
    // single global net. DONT_TOUCH prevents merging the local replicas.
    (* DONT_TOUCH="TRUE" *) reg [5:0] reset_local;
    always @(posedge clk) reset_local<={6{rst}};
    reg have_time,have_peak,have_frame,new_packet;
    reg [16:0] pending_vpp;
    reg [15:0] pending_rms;
    reg pending_signal;
    reg [1:0] pending_count;
    reg [35:0] pending_bins;
    reg [95:0] pending_mags;
    reg [16:0] raw_vpp;
    reg [15:0] raw_rms;
    reg source_valid,cal_valid,page_fft,three_cycles,held_single;
    reg [1:0] count;
    reg [35:0] active_bins;
    reg [95:0] mags;
    reg [31:0] gain_vpp,gain_rms,gain_fft,id,epoch,fmin,fmax;
    reg [3:0] fault;
    reg page_known,current_page,session_synced;
    reg [31:0] page_age;
    reg [31:0] startup_count;
    reg [4:0] field;
    reg [127:0] field_name;
    reg [31:0] field_value;
    reg field_valid;
    reg [7:0] sign_char;
    reg [159:0] text_value;
    reg [511:0] command;
    reg [6:0] command_length;
    reg command_page;
    // Serial ASCII construction replaces a wide length-priority encoder and
    // data-dependent 512-bit barrel shifts. Each cycle appends at most ONE byte.
    reg [127:0] build_name;
    reg [159:0] build_value;
    reg [47:0] build_suffix;
    reg [6:0] build_left;
    reg [511:0] length_scan;
    reg [3:0] digit_index;
    reg digit_started;
    wire command_ready,command_done;
    wire wave_ready,wave_axis,wave_pixel_valid,wave_done;
    wire [15:0] amax,wave_index;
    wire [7:0] wave_y;
    wire wave_plot_valid,wave_clamped;
    reg wave_finished;
    wire spec_ready,spec_axis,spec_pixel_valid,spec_done;
    wire [15:0] spec_index;
    wire [7:0] spec_y;
    wire [31:0] spec_scale;
    wire spec_plot_valid,spec_collision,spec_range;
    wire cal_ready,cal_out;
    wire [31:0] uv_vpp,uv_rms,uv_amax;
    wire [95:0] uv_peaks,frequencies;
    wire voltage_valid,voltage_overflow;
    reg [31:0] fft_scale_uv;
    wire mv_ready,mv_valid,mv_last;
    wire [7:0] mv_byte;
    wire [39:0] bcd;
    wire bcd_done;
    wire pixel_valid=page_fft?spec_pixel_valid:wave_pixel_valid;
    wire [7:0] logical_y=page_fft?spec_y:wave_y;
    wire [7:0] screen_y=INVERT_Y?(H-1-logical_y):logical_y;
    wire [15:0] pixel_index=page_fft?spec_index:wave_index;
    // Nonselected wave stream drains only on FFT transactions. Selected pixel
    // is accepted after its complete add command is assembled into command.
    wire take_pixel=state==PLOT && pixel_valid;
    wire take_wave=page_fft?1'b1:take_pixel;
    assign busy=state!=IDLE;
    assign state_debug=state;

    function [6:0] ascii_length;
        input [511:0] value;
        integer k;
        begin ascii_length=0;for(k=0;k<64;k=k+1) if(value[k*8+:8]!=0) ascii_length=k+1;end
    endfunction
    // Small decimal control fields use constant-size conversion, no divider.
    function [31:0] small_decimal;
        input [7:0] value;reg [7:0] hundreds,tens,ones;
        begin
            hundreds=value/100;tens=(value%100)/10;ones=value%10;
            if(value>=100) small_decimal={8'd0,8'd48+hundreds,8'd48+tens,8'd48+ones};
            else if(value>=10) small_decimal={16'd0,8'd48+tens,8'd48+ones};
            else small_decimal={24'd0,8'd48+ones};
        end
    endfunction
    task queue_command;
        input [511:0] value;input page;input [4:0] next_state;
        begin command<=value;command_length<=0;command_page<=page;
            length_scan<=value;build_left<=64;
            resume_state<=next_state;state<=COMMAND_LENGTH;end
    endtask
    task queue_text;
        input [127:0] name;input [159:0] value;
        begin
            build_name<=name;build_value<=value;build_suffix<=48'h2e7478743d22;
            build_left<=16;command<=0;command_length<=0;command_page<=0;
            resume_state<=FIELDS;state<=BUILD_NAME;field<=field+1'b1;
        end
    endtask
    task format_mv;
        input [127:0] name;input [31:0] value;input valid_value;input [7:0] sign_value;
        begin field_name<=name;field_value<=value;field_valid<=valid_value;
            sign_char<=sign_value;text_value<=0;state<=MV_START;end
    endtask
    task format_frequency;
        input [127:0] name;input [31:0] value;input valid_value;
        begin
            if(valid_value) begin field_name<=name;field_value<=value;state<=BCD_START;end
            else queue_text(name,"--");
        end
    endtask

    Display_UART_Command #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.BAUD_RATE(BAUD_RATE),
        .COMMAND_GAP_CYCLES(COMMAND_GAP_CYCLES),.PAGE_GAP_CYCLES(PAGE_GAP_CYCLES)) u_command(
        .clk(clk),.rst(reset_local[1]),.in_valid(state==SEND),.in_ready(command_ready),
        .command(command),.length(command_length),.is_page(command_page),
        .uart_tx(uart_tx),.tx_idle(tx_idle),.done(command_done));
    Display_Wave_Renderer #(.FRAME_LENGTH(FRAME_LENGTH),.ADDR_WIDTH(ADDR_WIDTH),.W(W),.H(H)) u_wave(
        .clk(clk),.rst(reset_local[2]),.in_valid(state==WAVE_START),.in_ready(wave_ready),
        .signal_valid(source_valid),.three_cycles(three_cycles),.fundamental_bin(active_bins[11:0]),.frame_id(id),
        .rd_en(time_rd_en),.rd_addr(time_rd_addr),.rd_data(time_rd_data),
        .axis_valid(wave_axis),.amax_raw(amax),.plot_valid(wave_plot_valid),.window_clamped(wave_clamped),
        .pixel_valid(wave_pixel_valid),.pixel_ready(take_wave),.pixel_index(wave_index),.pixel_y(wave_y),
        .frame_id_out(),.done(wave_done),.busy());
    Display_Frame_Calibrator u_cal(
        .clk(clk),.rst(reset_local[3]),.in_valid(state==CAL_START),.in_ready(cal_ready),
        .signal_valid(source_valid),.calibration_valid(cal_valid),.vpp_raw(raw_vpp),.rms_raw(raw_rms),.amax_raw(amax),
        .component_count(count),.component_bins(active_bins),.component_magnitudes(mags),
        .vpp_gain(gain_vpp),.rms_gain(gain_rms),.fft_gain(gain_fft),.frame_id(id),.epoch(epoch),.metadata(8'd0),
        .out_valid(cal_out),.out_ready(state==CAL_WAIT),.vpp_uv(uv_vpp),.rms_uv(uv_rms),.amax_uv(uv_amax),
        .peaks_uv(uv_peaks),.frequencies_hz(frequencies),.count_out(),.frame_id_out(),.epoch_out(),.metadata_out(),
        .signal_valid_out(),.calibration_valid_out(),.voltage_valid(voltage_valid),.overflow(voltage_overflow));
    Display_Spectrum_Renderer #(.W(W),.H(H)) u_spec(
        .clk(clk),.rst(reset_local[4]),.in_valid(state==SPEC_START),.in_ready(spec_ready),
        .signal_valid(source_valid),.component_count(count),.frequencies_hz(frequencies),.magnitudes_raw(mags),
        .frequency_min(fmin),.frequency_max(fmax),.frame_id(id),
        .axis_valid(spec_axis),.plot_valid(spec_plot_valid),.collision(spec_collision),.out_of_range(spec_range),
        .scale_raw(spec_scale),.frame_id_out(),.pixel_valid(spec_pixel_valid),.pixel_ready(page_fft && take_pixel),
        .pixel_index(spec_index),.pixel_y(spec_y),.done(spec_done),.busy());
    Display_mV_Formatter u_mv(.clk(clk),.rst(reset_local[5]),.in_valid(state==MV_START),.in_ready(mv_ready),
        .voltage_valid(field_valid),.microvolts(field_value),.byte_valid(mv_valid),.byte_ready(state==MV_WAIT),
        .byte_data(mv_byte),.byte_last(mv_last),.done());
    BIN2BCD #(.INPUT_WIDTH(32),.DIGITS(10)) u_bcd(.clk(clk),.rst(reset_local[5]),
        .start(state==BCD_START),.binary_in(field_value),.bcd_out(bcd),.busy(),.done(bcd_done));

    // synthesis translate_off
    initial if(CURVE_ID>255 || CHANNEL_ID>3 || STARTUP_CYCLES<0)
        $fatal(1,"Invalid display protocol configuration");
    // synthesis translate_on
    always @(posedge clk) begin
        if(reset_local[0]) begin
            state<=IDLE;resume_state<=IDLE;have_time<=0;have_peak<=0;have_frame<=0;new_packet<=0;
            pending_vpp<=0;pending_rms<=0;pending_signal<=0;pending_count<=0;pending_bins<=0;pending_mags<=0;
            raw_vpp<=0;raw_rms<=0;source_valid<=0;cal_valid<=0;page_fft<=0;three_cycles<=0;held_single<=0;
            count<=0;active_bins<=0;mags<=0;gain_vpp<=0;gain_rms<=0;gain_fft<=0;id<=0;epoch<=0;fmin<=0;fmax<=0;
            fault<=0;page_known<=0;current_page<=0;session_synced<=0;page_age<=0;startup_count<=0;field<=0;field_name<=0;field_value<=0;
            field_valid<=0;sign_char<=0;text_value<=0;command<=0;command_length<=0;command_page<=0;
            build_name<=0;build_value<=0;build_suffix<=0;build_left<=0;length_scan<=0;
            digit_index<=0;digit_started<=0;
            wave_finished<=0;fft_scale_uv<=0;frame_release<=0;measurement_valid<=0;signal_valid_out<=0;waveform_done<=0;
        end else begin
            measurement_valid<=0;waveform_done<=0;
            if(startup_count<STARTUP_CYCLES) startup_count<=startup_count+1'b1;
            if(wave_done) wave_finished<=1;
            if(time_result_valid) begin pending_vpp<=vpp_raw;pending_rms<=rms_raw;have_time<=1;end
            if(peak_result_valid) begin
                pending_signal<=signal_valid;pending_count<=component_count;
                pending_bins<=component_bins;pending_mags<=component_magnitudes;have_peak<=1;
            end
            if(capture_start) begin have_frame<=0;have_time<=0;have_peak<=0;frame_release<=0;end
            case(state)
                IDLE: begin
                    if(have_time && have_peak && !capture_start) begin
                        raw_vpp<=pending_vpp;raw_rms<=pending_rms;
                        source_valid<=pending_signal && pending_count!=0;
                        signal_valid_out<=pending_signal && pending_count!=0;
                        count<=pending_signal?pending_count:2'd0;active_bins<=pending_signal?pending_bins:36'd0;
                        mags<=pending_signal?pending_mags:96'd0;
                        id<=frame_id;
                        fmin<=10000;fmax<=(mode==0)?200000:500000;fault<=error_code;
                        page_fft<=page_fft_request;three_cycles<=three_cycles_request;held_single<=single_mode;
                        have_time<=0;have_peak<=0;have_frame<=1;frame_release<=0;new_packet<=1;
                        wave_finished<=0;measurement_valid<=1;state<=WAVE_START;
                    end else if(have_frame && allow_redraw && !capture_start &&
                        (page_fft!=page_fft_request || three_cycles!=three_cycles_request)) begin
                        page_fft<=page_fft_request;three_cycles<=three_cycles_request;
                        frame_release<=0;new_packet<=0;wave_finished<=0;state<=WAVE_START;
                    end
                end
                WAVE_START:begin
                    // This is the edge on which external consumers observe
                    // measurement_valid. Runtime_Calibration gives that event
                    // priority over bank commits, so ILA and display see the
                    // same pre-edge epoch/gains even if a VIO request collides.
                    if(new_packet) begin
                        gain_vpp<=vpp_gain;gain_rms<=rms_gain;gain_fft<=fft_gain;
                        cal_valid<=calibration_valid;epoch<=calibration_epoch;new_packet<=0;
                    end
                    if(wave_ready) state<=WAVE_AXIS;
                end
                WAVE_AXIS:if(wave_axis) state<=CAL_START;
                CAL_START:if(cal_ready) state<=CAL_WAIT;
                CAL_WAIT:if(cal_out) state<=page_fft?SPEC_START:PREPARE_PAGE;
                SPEC_START:if(spec_ready) state<=SPEC_AXIS;
                SPEC_AXIS:if(spec_axis) begin
                    // Select calibrated scale from the SAME raw component.
                    if(spec_scale==mags[31:0]) fft_scale_uv<=uv_peaks[31:0];
                    else if(spec_scale==mags[63:32]) fft_scale_uv<=uv_peaks[63:32];
                    else fft_scale_uv<=uv_peaks[95:64];
                    state<=PREPARE_PAGE;
                end
                PREPARE_PAGE:if(startup_count>=STARTUP_CYCLES) begin
                    field<=0;
                    // A reset may interrupt an ASCII command. Flush the screen
                    // parser before the first page command (empty payload => FFx3).
                    if(!session_synced) begin
                        session_synced<=1;queue_command(512'd0,0,PREPARE_PAGE);
                    end else if(!page_known || current_page!=page_fft ||
                       (PAGE_REFRESH_FRAMES>0 && page_age>=PAGE_REFRESH_FRAMES-1)) begin
                        page_known<=1;current_page<=page_fft;page_age<=0;
                        queue_command((512'h7061676520<<(ascii_length(page_fft?PAGE_FFT:PAGE_WAVE)*8))|
                            (page_fft?PAGE_FFT:PAGE_WAVE),1,FIELDS);
                    end else begin page_age<=page_age+1'b1;state<=FIELDS;end
                end
                FIELDS:begin
                    if(!page_fft) case(field)
                        0:format_mv(NAME_VPP,uv_vpp,voltage_valid,0);
                        1:format_mv(NAME_RMS,uv_rms,voltage_valid,0);
                        2:format_frequency(NAME_F1,frequencies[31:0],source_valid && count!=0);
                        3:format_mv(NAME_WTOP,uv_amax,voltage_valid,"+");
                        4:queue_text(NAME_WZERO,"0");
                        5:format_mv(NAME_WBOT,uv_amax,voltage_valid,"-");
                        6:queue_text(NAME_SPAN,three_cycles?"3T":"1T");
                        7:queue_text(NAME_WLEFT,"0T");
                        8:queue_text(NAME_WRIGHT,three_cycles?"3T":"1T");
                        default:state<=CLEAR;
                    endcase
                    else case(field)
                        0:format_frequency(NAME_F1,frequencies[31:0],source_valid && count>0);
                        1:format_mv(NAME_A1,uv_peaks[31:0],voltage_valid && count>0,0);
                        2:format_frequency(NAME_F2,frequencies[63:32],source_valid && count>1);
                        3:format_mv(NAME_A2,uv_peaks[63:32],voltage_valid && count>1,0);
                        4:format_frequency(NAME_F3,frequencies[95:64],source_valid && count>2);
                        5:format_mv(NAME_A3,uv_peaks[95:64],voltage_valid && count>2,0);
                        6:format_mv(NAME_FTOP,fft_scale_uv,voltage_valid && spec_plot_valid,0);
                        7:queue_text(NAME_FZERO,"0");
                        8:queue_text(NAME_FLEFT,"10kHz");
                        9:queue_text(NAME_FRIGHT,(fmax==200000)?"200kHz":"500kHz");
                        default:state<=CLEAR;
                    endcase
                end
                MV_START:if(mv_ready) begin
                    text_value<=field_valid?{152'd0,sign_char}:160'd0;state<=MV_WAIT;
                end
                MV_WAIT:if(mv_valid) begin
                    text_value<=(text_value<<8)|mv_byte;
                    if(mv_last) state<=MV_QUEUE;
                end
                MV_QUEUE:if(!field_valid) queue_text(field_name,"--");
                    else queue_text(field_name,(text_value<<16)|16'h6d56);
                BCD_START:state<=BCD_WAIT;
                BCD_WAIT:if(bcd_done) begin
                    digit_index<=9;digit_started<=0;text_value<=0;state<=BCD_DIGITS;
                end
                BCD_DIGITS:begin
                    if(digit_started || bcd[digit_index*4+:4]!=0 || digit_index==0) begin
                        text_value<=(text_value<<8)|(8'd48+bcd[digit_index*4+:4]);digit_started<=1;
                    end
                    if(digit_index==0) state<=BCD_QUEUE;else digit_index<=digit_index-1'b1;
                end
                BCD_QUEUE:queue_text(field_name,(text_value<<16)|16'h487a);
                BUILD_NAME:begin
                    if(build_name[127:120]!=0) begin
                        command<=(command<<8)|build_name[127:120];command_length<=command_length+1'b1;
                    end
                    build_name<=build_name<<8;build_left<=build_left-1'b1;
                    if(build_left==1) begin build_left<=6;state<=BUILD_SUFFIX;end
                end
                BUILD_SUFFIX:begin
                    command<=(command<<8)|build_suffix[47:40];command_length<=command_length+1'b1;
                    build_suffix<=build_suffix<<8;build_left<=build_left-1'b1;
                    if(build_left==1) begin build_left<=20;state<=BUILD_VALUE;end
                end
                BUILD_VALUE:begin
                    if(build_value[159:152]!=0) begin
                        command<=(command<<8)|build_value[159:152];command_length<=command_length+1'b1;
                    end
                    build_value<=build_value<<8;build_left<=build_left-1'b1;
                    if(build_left==1) state<=BUILD_CLOSE;
                end
                BUILD_CLOSE:begin
                    command<=(command<<8)|8'h22;command_length<=command_length+1'b1;state<=SEND;
                end
                COMMAND_LENGTH:begin
                    if(length_scan[511:504]!=0) begin command_length<=build_left;state<=SEND;end
                    else if(build_left==1) begin command_length<=0;state<=SEND;end
                    else begin length_scan<=length_scan<<8;build_left<=build_left-1'b1;end
                end
                SEND:if(command_ready) state<=SEND_WAIT;
                SEND_WAIT:if(command_done) state<=resume_state;
                CLEAR:begin
                    if(ENABLE_STATUS && field<31) begin
                        queue_text(NAME_STATUS,
                            (fault!=0)?"FAULT":(!source_valid?"NO SIGNAL":(voltage_overflow?"OVERFLOW":
                            (!voltage_valid?"CAL":(held_single?"HOLD":"RUN")))));
                        field<=31;resume_state<=CLEAR;
                    end else queue_command((512'h636c6520<<((ascii_length(small_decimal(CURVE_ID))+
                        ascii_length(small_decimal(CHANNEL_ID))+1)*8))|
                        ({480'd0,small_decimal(CURVE_ID)}<<((ascii_length(small_decimal(CHANNEL_ID))+1)*8))|
                        (512'h2c<<(ascii_length(small_decimal(CHANNEL_ID))*8))|small_decimal(CHANNEL_ID),0,PLOT);
                end
                PLOT:if(take_pixel) begin
                    queue_command((512'h61646420<<((ascii_length(small_decimal(CURVE_ID))+
                        ascii_length(small_decimal(CHANNEL_ID))+ascii_length(small_decimal(screen_y))+2)*8))|
                        ({480'd0,small_decimal(CURVE_ID)}<<((ascii_length(small_decimal(CHANNEL_ID))+
                            ascii_length(small_decimal(screen_y))+2)*8))|
                        (512'h2c<<((ascii_length(small_decimal(CHANNEL_ID))+ascii_length(small_decimal(screen_y))+1)*8))|
                        ({480'd0,small_decimal(CHANNEL_ID)}<<((ascii_length(small_decimal(screen_y))+1)*8))|
                        (512'h2c<<(ascii_length(small_decimal(screen_y))*8))|small_decimal(screen_y),0,
                        (pixel_index==W-1)?FINISH:PLOT);
                end
                FINISH:if(wave_finished && tx_idle) begin
                    frame_release<=1;waveform_done<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
