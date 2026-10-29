`timescale 1ns/1ps
// Transaction owner, all ports synchronous to clk. Mode and cycle selection
// remain immutable from arming through the final UART stop bit. No clock gating.
// SW3(C)>SW2(B)>SW1(A)>SW0(debug); all off -> A. SINGLE at boot waits for BtnD.
module Run_Controller #(
    parameter integer TIMEOUT_CYCLES=200_000_000
)(
    input wire clk, rst,
    input wire controls_ready,
    input wire [3:0] mode_switches,
    input wire single_request,
    input wire start_pulse, cycle_pulse, left_pulse, right_pulse,
    input wire frame_start,
    input wire measurement_valid,
    input wire packet_finished,
    input wire acquisition_fault,
    output wire capture_enable,
    output wire frame_release,
    output reg [1:0] mode_active,
    output reg single_active, three_cycles_active,
    output reg [1:0] view_active,
    // UI requests may change during HOLD; measurement mode/view_active keep
    // their original transaction-latched semantics for board diagnostics.
    output wire display_three_cycles_request,
    output wire [1:0] display_view_request,
    output reg [31:0] frame_id,
    output wire result_fresh,
    output reg [3:0] error_code,
    output reg [31:0] latency_cycles,
    output wire [2:0] state_debug
);
    localparam [2:0] IDLE=0, ARMED=1, RUN=2, DRAIN=3, FAULT=4;
    localparam integer CW=(TIMEOUT_CYCLES<2)?1:$clog2(TIMEOUT_CYCLES);
    reg [2:0] state;
    reg pending, cycles_requested, have_result;
    reg [1:0] view_requested;
    reg [CW-1:0] timer, result_age;
    reg [1:0] requested_mode;
    always @* begin
        if(mode_switches[3]) requested_mode=2;
        else if(mode_switches[2]) requested_mode=1;
        else if(mode_switches[1]) requested_mode=0;
        else if(mode_switches[0]) requested_mode=3;
        else requested_mode=0;
    end
    // Reserve the final deadline cycle for observing frame_start. Otherwise
    // AFE could accept a crossing on the very edge on which we time out.
    assign capture_enable=(state==ARMED && timer<TIMEOUT_CYCLES-1);
    // AFE can rearm while IDLE, but may not start without capture_enable.
    // Never pass the previous HMI packet's still-high release to a new frame.
    assign frame_release=(state==IDLE || state==ARMED);
    assign state_debug=state;
    assign display_three_cycles_request=cycles_requested;
    assign display_view_request=view_requested;
    assign result_fresh=have_result && (single_active || result_age<TIMEOUT_CYCLES-1);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; pending<=0; cycles_requested<=0; view_requested<=0;
            mode_active<=0; single_active<=0; three_cycles_active<=0; view_active<=0;
            frame_id<=0; have_result<=0; error_code<=0; timer<=0;
            result_age<=0; latency_cycles<=0;
        end else begin
            if(start_pulse) pending<=1; // one-entry request, never replay many clicks
            if(cycle_pulse) cycles_requested<=~cycles_requested;
            if(right_pulse) view_requested<=view_requested+1'b1;
            else if(left_pulse) view_requested<=view_requested-1'b1;
            if(have_result && result_age<TIMEOUT_CYCLES-1) result_age<=result_age+1'b1;
            if(state!=IDLE && timer<TIMEOUT_CYCLES-1) timer<=timer+1'b1;
            if(acquisition_fault && state!=IDLE) error_code<=4'h2;
            case(state)
                IDLE: begin
                    timer<=0;
                    if(controls_ready && (!single_request || pending || start_pulse)) begin
                        mode_active<=requested_mode;
                        single_active<=single_request;
                        three_cycles_active<=cycles_requested;
                        view_active<=view_requested;
                        frame_id<=frame_id+1'b1;
                        have_result<=0; pending<=0; state<=ARMED;
                    end
                end
                ARMED: begin
                    if(frame_start) state<=RUN;
                    else if(timer==TIMEOUT_CYCLES-1) begin
                        // No frame has started, so it is safe to retry from IDLE.
                        error_code<=1; have_result<=0; state<=IDLE;
                    end
                end
                RUN: begin
                    if(measurement_valid) begin
                        have_result<=1; result_age<=0;
                        latency_cycles<=timer; state<=DRAIN;
                    end else if(timer==TIMEOUT_CYCLES-1) begin
                        error_code<=1; state<=FAULT;
                    end
                end
                DRAIN: begin
                    // packet_finished includes UART idle, NOT merely byte accepted.
                    if(packet_finished) begin latency_cycles<=timer; state<=IDLE; end
                    else if(timer==TIMEOUT_CYCLES-1) begin error_code<=1; state<=FAULT; end
                end
                FAULT: begin
                    // Do not overwrite a possibly live consumer. A late complete
                    // packet is safe to retire; a genuinely hung pipeline needs reset.
                    if(measurement_valid) begin have_result<=1; result_age<=0; end
                    if(have_result && packet_finished) state<=IDLE;
                end
                default: begin state<=FAULT; error_code<=4'hf; end
            endcase
        end
    end
endmodule
