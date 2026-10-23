`timescale 1ns/1ps
// Numeric voltage fields remain RAW until calibrated. View0 shows kHz with
// one decimal digit (Hz/100); views1/2/3 show Vpp/RMS/magnitude raw integers.
// All four numbers are latched on the SAME measurement_valid event.
module Board_Status_Display #(
    parameter integer CLK_HZ=100_000_000,
    parameter integer SCAN_CYCLES=25_000,
    parameter integer DISPLAY_HOLD_CYCLES=2*CLK_HZ,
    parameter integer VALIDATE_SIGNAL=0
)(
    input wire clk, rst, locked, measurement_valid, fresh,
    input wire signal_valid,
    input wire capture_busy, algorithm_busy, hmi_busy,
    input wire [1:0] mode, view,
    input wire single_mode, three_cycles,
    input wire [3:0] error_code,
    input wire [31:0] frequency_hz, magnitude_raw,
    input wire [16:0] vpp_raw,
    input wire [15:0] rms_raw,
    output wire [15:0] led,
    output wire [6:0] seg,
    output wire [3:0] an,
    output wire dp
);
    localparam integer HC=(CLK_HZ<2)?1:CLK_HZ/2;
    localparam integer PC=(CLK_HZ<10)?1:CLK_HZ/10;
    reg [31:0] heartbeat_count, pulse_count;
    reg heartbeat;
    reg [31:0] f_display, a_snap;
    // Serial unsigned /100: one 8-bit compare/subtract per cycle, not a
    // 32-bit combinational constant divider on the display's critical path.
    // Quotient is published atomically after 32 clocks; measurement events
    // restart the operation from the newest same-frame frequency snapshot.
    reg [31:0] freq_shift, freq_quotient;
    reg [6:0] freq_remainder;
    reg [5:0] freq_bits;
    wire [7:0] freq_trial={freq_remainder,freq_shift[31]};
    wire freq_subtract=(freq_trial>=8'd100);
    wire [7:0] freq_next_remainder=freq_subtract ? freq_trial-8'd100 : freq_trial;
    wire [31:0] freq_next_quotient={freq_quotient[30:0],freq_subtract};
    reg [16:0] p_snap;
    reg [15:0] r_snap;
    reg [31:0] display_value;
    // The controller's 'fresh' deliberately drops while the next transaction
    // runs. It drives LD6, NOT digit blanking: retain the last complete reading
    // during that short interval. Continuous-mode data expires after 2 s;
    // LD10 explicitly identifies indefinite single-shot HOLD. A mode change
    // invalidates the old reading even if the user switches back quickly.
    reg have_snapshot;
    reg [31:0] display_age;
    reg [1:0] snapshot_mode;
    wire display_valid=have_snapshot && mode==snapshot_mode &&
        (single_mode || display_age<DISPLAY_HOLD_CYCLES-1);
    always @(posedge clk) begin
        if(rst) begin
            heartbeat_count<=0; pulse_count<=0; heartbeat<=0;
            f_display<=0; a_snap<=0; p_snap<=0; r_snap<=0;
            freq_shift<=0; freq_quotient<=0; freq_remainder<=0; freq_bits<=0;
            have_snapshot<=0; display_age<=0; snapshot_mode<=0;
        end else begin
            if(display_age<DISPLAY_HOLD_CYCLES-1) display_age<=display_age+1'b1;
            if(mode!=snapshot_mode) have_snapshot<=0;
            if(heartbeat_count==HC-1) begin heartbeat_count<=0; heartbeat<=~heartbeat; end
            else heartbeat_count<=heartbeat_count+1'b1;
            if(measurement_valid) begin
                pulse_count<=PC;
                a_snap<=magnitude_raw; p_snap<=vpp_raw; r_snap<=rms_raw;
                if(VALIDATE_SIGNAL && !signal_valid) begin
                    have_snapshot<=0;freq_bits<=0;
                end else begin
                    freq_shift<=frequency_hz; freq_quotient<=0; freq_remainder<=0; freq_bits<=32;
                end
                display_age<=0; snapshot_mode<=mode;
            end else if(pulse_count!=0) pulse_count<=pulse_count-1'b1;
            if(!measurement_valid && freq_bits!=0) begin
                freq_shift<={freq_shift[30:0],1'b0};
                freq_quotient<=freq_next_quotient;
                freq_remainder<=freq_next_remainder[6:0];
                freq_bits<=freq_bits-1'b1;
                if(freq_bits==1) begin f_display<=freq_next_quotient;have_snapshot<=1;end
            end
        end
    end
    always @* begin
        case(view)
            0:display_value=f_display; // Hz/100; 100.0 kHz -> 1000
            1:display_value={15'd0,p_snap};
            2:display_value={16'd0,r_snap};
            default:display_value=a_snap;
        endcase
    end
    assign led={error_code,three_cycles,single_mode,mode,(|error_code),
                (fresh && (!VALIDATE_SIGNAL || signal_valid)),
                hmi_busy,algorithm_busy,capture_busy,(pulse_count!=0),heartbeat,locked};
    SevenSeg_Scan #(.SCAN_CYCLES(SCAN_CYCLES)) u_scan(
        .clk(clk),.rst(rst),.value(display_value),.valid(display_valid),
        .decimal_points((view==0)?4'b0010:4'b0000),.seg(seg),.an(an),.dp(dp));
endmodule
