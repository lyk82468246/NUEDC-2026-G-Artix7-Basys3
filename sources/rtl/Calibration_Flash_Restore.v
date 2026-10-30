`timescale 1ns/1ps
// READ-ONLY startup/reload sequencer. No flash write path exists here.
// EXPECTED_JEDEC=0 (default) permits status/ID only, then returns defaults.
// Candidate addresses MUST be frozen against actual capacity/profile before
// setting EXPECTED_JEDEC. Reset is POR only, not the front-panel reset.
module Calibration_Flash_Restore #(
    parameter [23:0] EXPECTED_JEDEC=24'd0,
    parameter [23:0] SLOT_A=24'h3e0000,SLOT_B=24'h3f0000,
    parameter integer HALF_PERIOD=4,POLL_GAP=1000,MAX_POLLS=100000
)(
    input wire clk,por,reload_valid,output wire reload_ready,
    output reg out_valid,input wire out_ready,
    output reg record_valid,output reg [96:0] bank,
    output reg [31:0] record_sequence,saved_epoch,
    output reg [1:0] source,output reg [3:0] error_code,
    output reg [23:0] jedec_id,output reg [7:0] status_register,output wire busy,
    output wire cs_n,sck,mosi,input wire miso
);
    localparam STATUS_CMD=0,STATUS_RX=1,DELAY=2,ID_CMD=3,ID_RX=4,PROFILE=5,
        DEC_START=6,READ_CMD=7,READ_RX=8,DEC_WAIT=9,SELECT=10,SELECT_WAIT=11,RESULT=12,IDLE=13;
    reg [3:0] state;
    reg [31:0] polls,timer;
    reg slot,commit_part;
    reg a_valid,b_valid;
    reg [96:0] a_bank,b_bank;
    reg [31:0] a_seq,b_seq,a_epoch,b_epoch;
    wire command_ready,stream_valid,stream_last,engine_error;
    wire [7:0] stream;
    wire decoder_ready,decoder_byte_ready,decoder_valid,decoded_ok,decoded_enabled;
    wire [31:0] decoded_seq,decoded_epoch,decoded_vpp,decoded_rms,decoded_fft;
    wire select_ready,select_valid,select_ok;
    wire [96:0] selected_bank;
    wire [31:0] selected_seq,selected_epoch;
    wire [1:0] selected_source;
    wire stream_ready=(state==STATUS_RX || state==ID_RX || (state==READ_RX && decoder_byte_ready));
    wire [24:0] read_address={1'b0,(slot?SLOT_B:SLOT_A)}+(commit_part?25'd256:25'd0);
    assign busy=state!=IDLE && state!=RESULT;
    assign reload_ready=!por && state==IDLE;
    Flash_Read_Engine #(.HALF_PERIOD(HALF_PERIOD)) u_reader(
        .clk(clk),.por(por),.cmd_valid(state==STATUS_CMD || state==ID_CMD || state==READ_CMD),
        .cmd_ready(command_ready),.cmd_kind(state==STATUS_CMD?2'd1:(state==ID_CMD?2'd0:2'd2)),
        .cmd_address(read_address[23:0]),.cmd_length(commit_part?16'd16:16'd64),
        .data_valid(stream_valid),.data_ready(stream_ready),.data(stream),.data_last(stream_last),
        .busy(),.done(),.error(engine_error),.cs_n(cs_n),.sck(sck),.mosi(mosi),.miso(miso));
    Calibration_Record_Decoder u_decoder(
        .clk(clk),.por(por),.in_valid(state==DEC_START),.in_ready(decoder_ready),
        .byte_valid(state==READ_RX && stream_valid),.byte_ready(decoder_byte_ready),.byte_data(stream),
        .out_valid(decoder_valid),.out_ready(state==DEC_WAIT),.record_valid(decoded_ok),
        .record_sequence(decoded_seq),.saved_epoch(decoded_epoch),.enabled(decoded_enabled),
        .vpp_gain(decoded_vpp),.rms_gain(decoded_rms),.fft_gain(decoded_fft));
    Calibration_Record_Select u_select(
        .clk(clk),.por(por),.in_valid(state==SELECT),.in_ready(select_ready),
        .a_valid(a_valid),.b_valid(b_valid),.a_bank(a_bank),.b_bank(b_bank),
        .a_sequence(a_seq),.b_sequence(b_seq),.a_epoch(a_epoch),.b_epoch(b_epoch),
        .out_valid(select_valid),.out_ready(state==SELECT_WAIT),.record_valid(select_ok),
        .source(selected_source),.bank(selected_bank),.record_sequence(selected_seq),.saved_epoch(selected_epoch));
    // synthesis translate_off
    initial if(POLL_GAP<1 || MAX_POLLS<1 || SLOT_A[7:0]!=0 || SLOT_B[7:0]!=0 ||
        {1'b0,SLOT_A}+25'd272>25'h1000000 || {1'b0,SLOT_B}+25'd272>25'h1000000)
        $fatal(1,"Invalid read-only restore parameters");
    // synthesis translate_on
    always @(posedge clk)begin
        if(por)begin
            state<=STATUS_CMD;polls<=0;timer<=0;slot<=0;commit_part<=0;
            a_valid<=0;b_valid<=0;a_bank<=0;b_bank<=0;a_seq<=0;b_seq<=0;a_epoch<=0;b_epoch<=0;
            out_valid<=0;record_valid<=0;bank<=0;record_sequence<=0;saved_epoch<=0;
            source<=0;error_code<=0;jedec_id<=0;status_register<=0;
        end else case(state)
            IDLE:if(reload_valid && reload_ready)begin
                polls<=0;record_valid<=0;error_code<=0;source<=0;bank<=0;record_sequence<=0;saved_epoch<=0;
                jedec_id<=0;state<=STATUS_CMD;
            end
            STATUS_CMD:if(command_ready)state<=STATUS_RX;
            STATUS_RX:if(stream_valid && stream_ready)begin
                status_register<=stream;
                if(stream[0])begin
                    if(polls==MAX_POLLS-1)begin error_code<=1;state<=RESULT;end
                    else begin polls<=polls+1'b1;timer<=POLL_GAP-1;state<=DELAY;end
                end else state<=ID_CMD;
            end
            DELAY:if(timer==0)state<=STATUS_CMD;else timer<=timer-1'b1;
            ID_CMD:if(command_ready)state<=ID_RX;
            ID_RX:if(stream_valid && stream_ready)begin
                jedec_id<={jedec_id[15:0],stream};if(stream_last)state<=PROFILE;
            end
            PROFILE:if(EXPECTED_JEDEC==0 || EXPECTED_JEDEC==24'hffffff || jedec_id!=EXPECTED_JEDEC)begin
                error_code<=2;state<=RESULT;
            end else begin slot<=0;commit_part<=0;state<=DEC_START;end
            DEC_START:if(decoder_ready)state<=READ_CMD;
            READ_CMD:if(command_ready)state<=READ_RX;
            READ_RX:if(stream_valid && stream_ready && stream_last)begin
                if(!commit_part)begin commit_part<=1;state<=READ_CMD;end
                else state<=DEC_WAIT;
            end
            DEC_WAIT:if(decoder_valid)begin
                if(!slot)begin
                    a_valid<=decoded_ok;a_bank<={decoded_enabled,decoded_vpp,decoded_rms,decoded_fft};
                    a_seq<=decoded_seq;a_epoch<=decoded_epoch;slot<=1;commit_part<=0;state<=DEC_START;
                end else begin
                    b_valid<=decoded_ok;b_bank<={decoded_enabled,decoded_vpp,decoded_rms,decoded_fft};
                    b_seq<=decoded_seq;b_epoch<=decoded_epoch;state<=SELECT;
                end
            end
            SELECT:if(select_ready)state<=SELECT_WAIT;
            SELECT_WAIT:if(select_valid)begin
                record_valid<=select_ok;bank<=selected_bank;record_sequence<=selected_seq;
                saved_epoch<=selected_epoch;source<=selected_source;
                error_code<=selected_source==3?4'd4:(select_ok?4'd0:4'd3);state<=RESULT;
            end
            RESULT:begin
                out_valid<=1;
                if(out_valid && out_ready)begin out_valid<=0;state<=IDLE;end
            end
            default:begin error_code<=5;record_valid<=0;state<=RESULT;end
        endcase
    end
endmodule
