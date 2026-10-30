`timescale 1ns/1ps
// MX25L3233F persistent calibration, format 1. All logic uses ONE clock.
// POR resets transport; panel_reset NEVER resets an in-flight flash operation.
// command 0=probe, 1=save APPLIED bank, 2=reload+apply, 3=reject.
// First 4KiB of each reserved 64KiB slot is used; no whole-chip erase exists.
module Calibration_Store #(
    parameter integer HALF_PERIOD=4,POLL_GAP=1000,MAX_POLLS=100000,
    parameter [96:0] DEFAULT_BANK={1'b1,32'd3623460,32'd3701829,32'd4194}
)(
    input wire clk,por,panel_reset,request_toggle,input wire [1:0] command,
    input wire [96:0] active_bank,input wire [31:0] active_epoch,
    input wire apply_pending,runtime_busy,
    output wire restore_valid,input wire restore_ready,output wire [96:0] restore_bank,
    output reg calibration_ready,output wire apply_block,
    output wire [31:0] status,output reg [23:0] jedec_id,
    output reg [31:0] saved_sequence,saved_epoch,output reg [96:0] saved_bank,
    output wire cs_n,sck,mosi,input wire miso
);
    localparam INIT=0,CMD=1,STATUS_START=2,STATUS_RX=3,ID_START=4,ID_RX=5,ID_CHECK=6,
        SECURITY_START=7,SECURITY_RX=8,DEC_START=9,RECORD_START=10,RECORD_RX=11,DEC_WAIT=12,
        SELECT_START=13,SELECT_WAIT=14,APPLY=15,COMPLETE=16,IDLE=17,WAIT_PANEL=18,
        ENCODE_START=19,ENCODE_WAIT=20,PREFLIGHT_START=21,PREFLIGHT_RX=22,PREFLIGHT_CHECK=23,
        WREN_START=24,WREN_WAIT=25,WEL_START=26,WEL_RX=27,WRITE_START=28,WRITE_WAIT=29,
        PP_STREAM=30,POLL_START=31,POLL_RX=32,POLL_GAP_WAIT=33,
        ERASE_VERIFY_START=34,ERASE_VERIFY_RX=35,ERASE_VERIFY_CHECK=36,
        BODY_VERIFY_START=37,BODY_VERIFY_RX=38,BODY_VERIFY_CHECK=39,
        VERIFY_RECORD=40,SAVE_COMPLETE=41;
    reg [5:0] state,continuation,security_next,poll_next;
    reg [2:0] descriptor;
    reg [23:0] descriptor_address;
    reg [15:0] descriptor_length;
    reg req1,req2,ack,inflight,initialized,pending_panel,rejected;
    reg saving,want_apply,verified,saved_valid;
    reg [1:0] saved_source;
    reg [3:0] error_code;
    reg [7:0] sr,security;
    reg [31:0] polls,timer,candidate_sequence,snapshot_epoch;
    reg [96:0] snapshot;
    reg slot,commit_part,verify_record;
    reg a_valid,b_valid;
    reg [96:0] a_bank,b_bank;
    reg [31:0] a_seq,b_seq,a_epoch,b_epoch;
    reg [12:0] index;
    reg foreign,magic_bad,compare_bad;
    reg [1:0] write_phase; // 0 erase, 1 body, 2 separate commit page
    wire [23:0] base=slot?24'h3f0000:24'h3e0000;
    wire engine_ready,engine_valid,engine_last,engine_done,engine_error,write_ready;
    wire [7:0] engine_data,encoded;
    wire encoder_ready,encoder_valid,decoder_ready,decoder_byte_ready,decoder_valid,decoded_ok,decoded_enabled;
    wire engine_take=(state==STATUS_RX || state==ID_RX || state==SECURITY_RX || state==WEL_RX ||
        state==POLL_RX || state==PREFLIGHT_RX || state==ERASE_VERIFY_RX || state==BODY_VERIFY_RX ||
        (state==RECORD_RX && decoder_byte_ready));
    wire [31:0] decoded_seq,decoded_epoch,decoded_vpp,decoded_rms,decoded_fft;
    wire [96:0] decoded_bank={decoded_enabled,decoded_vpp,decoded_rms,decoded_fft};
    wire [6:0] encoded_address=(write_phase==2?7'd64:7'd0)+index[6:0];
    wire selection_ready,selection_valid,selection_ok;
    wire [1:0] selection_source;
    wire [96:0] selection_bank;
    wire [31:0] selection_seq,selection_epoch;
    wire busy=state!=IDLE;
    wire dirty=!saved_valid || active_bank!=saved_bank;
    assign apply_block=busy || !calibration_ready || panel_reset;
    assign restore_valid=state==APPLY && !panel_reset;
    assign restore_bank=saved_valid?saved_bank:DEFAULT_BANK;
    assign status={security,sr,pending_panel,rejected,apply_block,saving,dirty,initialized,ack,
        error_code,saved_source,saved_valid,calibration_ready,busy};
    Flash_Command_Engine #(.HALF_PERIOD(HALF_PERIOD)) u_engine(
        .clk(clk),.por(por),.verified(verified),.cmd_valid(state==CMD),.cmd_ready(engine_ready),
        .cmd_kind(descriptor),.cmd_address(descriptor_address),.cmd_length(descriptor_length),
        .write_valid(state==PP_STREAM),.write_ready(write_ready),.write_data(encoded),
        .data_valid(engine_valid),.data_ready(engine_take),.data(engine_data),.data_last(engine_last),
        .done(engine_done),.error(engine_error),.busy(),.cs_n(cs_n),.sck(sck),.mosi(mosi),.miso(miso));
    Calibration_Record_Encoder u_encode(.clk(clk),.por(por),.in_valid(state==ENCODE_START),.in_ready(encoder_ready),
        .bank(snapshot),.record_sequence(candidate_sequence),.saved_epoch(snapshot_epoch),
        .out_valid(encoder_valid),.out_ready(state==ENCODE_WAIT),.rd_addr(encoded_address),.rd_data(encoded));
    Calibration_Record_Decoder u_decode(.clk(clk),.por(por),.in_valid(state==DEC_START),.in_ready(decoder_ready),
        .byte_valid(state==RECORD_RX && engine_valid),.byte_ready(decoder_byte_ready),.byte_data(engine_data),
        .out_valid(decoder_valid),.out_ready(state==DEC_WAIT),.record_valid(decoded_ok),
        .record_sequence(decoded_seq),.saved_epoch(decoded_epoch),.vpp_gain(decoded_vpp),
        .rms_gain(decoded_rms),.fft_gain(decoded_fft),.enabled(decoded_enabled));
    Calibration_Record_Select u_select(.clk(clk),.por(por),.in_valid(state==SELECT_START),.in_ready(selection_ready),
        .a_valid(a_valid),.b_valid(b_valid),.a_bank(a_bank),.b_bank(b_bank),.a_sequence(a_seq),.b_sequence(b_seq),
        .a_epoch(a_epoch),.b_epoch(b_epoch),.out_valid(selection_valid),.out_ready(state==SELECT_WAIT),
        .record_valid(selection_ok),.source(selection_source),.bank(selection_bank),
        .record_sequence(selection_seq),.saved_epoch(selection_epoch));
    task issue;
        input [2:0] op;input [23:0] address;input [15:0] length;input [5:0] next_state;
        begin descriptor<=op;descriptor_address<=address;descriptor_length<=length;
            continuation<=next_state;state<=CMD;end
    endtask
    task finish;
        input [3:0] code;
        begin error_code<=code;state<=want_apply?APPLY:COMPLETE;end
    endtask
    function [7:0] magic_byte;
        input [1:0] offset;
        begin case(offset)0:magic_byte="G";1:magic_byte="C";2:magic_byte="A";3:magic_byte="L";endcase end
    endfunction
    always @(posedge clk)begin
        if(por)begin
            state<=INIT;continuation<=INIT;security_next<=INIT;poll_next<=INIT;
            descriptor<=0;descriptor_address<=0;descriptor_length<=0;
            req1<=0;req2<=0;ack<=0;inflight<=0;initialized<=0;pending_panel<=0;rejected<=0;
            saving<=0;want_apply<=1;verified<=0;saved_valid<=0;calibration_ready<=0;saved_source<=0;
            error_code<=0;sr<=0;security<=0;jedec_id<=0;saved_sequence<=0;saved_epoch<=0;saved_bank<=0;
            polls<=0;timer<=0;candidate_sequence<=0;snapshot_epoch<=0;snapshot<=0;
            slot<=0;commit_part<=0;verify_record<=0;a_valid<=0;b_valid<=0;a_bank<=0;b_bank<=0;
            a_seq<=0;b_seq<=0;a_epoch<=0;b_epoch<=0;index<=0;foreign<=0;magic_bad<=0;compare_bad<=0;write_phase<=0;
        end else begin
            req1<=request_toggle;req2<=req1;
            if(initialized && busy && req2!=inflight)rejected<=1;
            case(state)
                INIT:begin
                    verified<=0;polls<=0;
                    if(!saving)begin saved_valid<=0;saved_source<=0;saved_bank<=0;saved_sequence<=0;saved_epoch<=0;end
                    state<=STATUS_START;
                end
                CMD:if(engine_ready)state<=continuation;
                STATUS_START:issue(1,0,1,STATUS_RX);
                STATUS_RX:if(engine_valid && engine_take)begin
                    sr<=engine_data;
                    if(engine_data[0])begin
                        if(polls==MAX_POLLS-1)finish(1);
                        else begin polls<=polls+1'b1;timer<=POLL_GAP-1;poll_next<=STATUS_START;state<=POLL_GAP_WAIT;end
                    end else begin jedec_id<=0;state<=ID_START;end
                end
                ID_START:issue(0,0,3,ID_RX);
                ID_RX:if(engine_valid && engine_take)begin jedec_id<={jedec_id[15:0],engine_data};if(engine_last)state<=ID_CHECK;end
                ID_CHECK:if(jedec_id!=24'hc22016)finish(2);
                    else begin security_next<=saving?ENCODE_START:DEC_START;slot<=0;commit_part<=0;verify_record<=0;state<=SECURITY_START;end
                SECURITY_START:issue(6,0,1,SECURITY_RX);
                SECURITY_RX:if(engine_valid && engine_take)begin
                    security<=engine_data;
                    if(saving && engine_data[7:5]!=0)finish(13);
                    else if(saving && (sr&8'hbc)!=0)finish(6);
                    else begin verified<=(sr&8'hbc)==0 && engine_data[7:5]==0;state<=security_next;end
                end
                DEC_START:if(decoder_ready)state<=RECORD_START;
                RECORD_START:issue(2,base+(commit_part?24'd256:24'd0),commit_part?16'd16:16'd64,RECORD_RX);
                RECORD_RX:if(engine_valid && engine_take && engine_last)begin
                    if(!commit_part)begin commit_part<=1;state<=RECORD_START;end else state<=DEC_WAIT;
                end
                DEC_WAIT:if(decoder_valid)begin
                    if(verify_record)begin
                        if(!decoded_ok || decoded_bank!=snapshot || decoded_seq!=candidate_sequence || decoded_epoch!=snapshot_epoch)finish(12);
                        else state<=SAVE_COMPLETE;
                    end else if(!slot)begin
                        a_valid<=decoded_ok;a_bank<=decoded_bank;a_seq<=decoded_seq;a_epoch<=decoded_epoch;
                        slot<=1;commit_part<=0;state<=DEC_START;
                    end else begin b_valid<=decoded_ok;b_bank<=decoded_bank;b_seq<=decoded_seq;b_epoch<=decoded_epoch;state<=SELECT_START;end
                end
                SELECT_START:if(selection_ready)state<=SELECT_WAIT;
                SELECT_WAIT:if(selection_valid)begin
                    saved_valid<=selection_ok;saved_source<=selection_source;saved_bank<=selection_bank;
                    saved_sequence<=selection_seq;saved_epoch<=selection_epoch;
                    finish(selection_source==3?4'd4:(selection_ok?4'd0:4'd3));
                end
                APPLY:if(restore_valid && restore_ready)state<=COMPLETE;
                COMPLETE:begin
                    ack<=req2;inflight<=req2;initialized<=1;saving<=0;
                    if(pending_panel || panel_reset)begin calibration_ready<=0;state<=WAIT_PANEL;end
                    else begin calibration_ready<=1;state<=IDLE;end
                end
                WAIT_PANEL:if(!panel_reset)begin pending_panel<=0;want_apply<=1;saving<=0;state<=INIT;end
                IDLE:begin
                    if(pending_panel || panel_reset)begin calibration_ready<=0;state<=WAIT_PANEL;end
                    else if(req2!=ack)begin
                        inflight<=req2;rejected<=0;want_apply<=command==2;error_code<=0;
                        if(command==3)begin error_code<=14;state<=COMPLETE;end
                        else if(apply_pending || runtime_busy)begin error_code<=8;want_apply<=0;state<=COMPLETE;end
                        else if(command==1)begin
                            want_apply<=0;
                            if(active_bank[95:64]==0 || active_bank[63:32]==0 || active_bank[31:0]==0)begin error_code<=7;state<=COMPLETE;end
                            else if(saved_source==3)begin error_code<=4;state<=COMPLETE;end
                            else if(saved_valid && active_bank==saved_bank)state<=COMPLETE;
                            else begin
                                snapshot<=active_bank;snapshot_epoch<=active_epoch;
                                candidate_sequence<=saved_valid?saved_sequence+1'b1:32'd0;
                                saving<=1;state<=INIT;
                            end
                        end else begin calibration_ready<=0;saving<=0;state<=INIT;end
                    end
                end
                ENCODE_START:if(encoder_ready)state<=ENCODE_WAIT;
                ENCODE_WAIT:if(encoder_valid)begin slot<=saved_source==1;index<=0;foreign<=0;magic_bad<=0;state<=PREFLIGHT_START;end
                PREFLIGHT_START:issue(2,base,4096,PREFLIGHT_RX);
                PREFLIGHT_RX:if(engine_valid && engine_take)begin
                    if(index<4 && engine_data!=8'hff && engine_data!=magic_byte(index[1:0]))magic_bad<=1;
                    if(index>=64 && !(index>=256 && index<272) && engine_data!=8'hff)foreign<=1;
                    if(engine_last)state<=PREFLIGHT_CHECK;else index<=index+1'b1;
                end
                PREFLIGHT_CHECK:if(foreign || magic_bad)finish(9);
                    else begin write_phase<=0;state<=WREN_START;end
                WREN_START:issue(3,base,0,WREN_WAIT);
                WREN_WAIT:if(engine_done)begin if(engine_error)finish(5);else state<=WEL_START;end
                WEL_START:issue(1,0,1,WEL_RX);
                WEL_RX:if(engine_valid && engine_take)begin
                    sr<=engine_data;
                    if(engine_data[0] || !engine_data[1] || (engine_data&8'hbc)!=0)finish(6);
                    else begin index<=0;state<=WRITE_START;end
                end
                WRITE_START:if(write_phase==0)issue(5,base,0,WRITE_WAIT);
                    else issue(4,base+(write_phase==2?24'd256:24'd0),write_phase==2?16'd16:16'd64,PP_STREAM);
                PP_STREAM:if(write_ready)begin
                    if(index==(write_phase==2?15:63))state<=WRITE_WAIT;else index<=index+1'b1;
                end
                WRITE_WAIT:if(engine_done)begin
                    if(engine_error)finish(5);
                    else begin polls<=0;poll_next<=write_phase==0?ERASE_VERIFY_START:(write_phase==1?BODY_VERIFY_START:VERIFY_RECORD);state<=POLL_START;end
                end
                POLL_START:issue(1,0,1,POLL_RX);
                POLL_RX:if(engine_valid && engine_take)begin
                    sr<=engine_data;
                    if(engine_data[0])begin
                        if(polls==MAX_POLLS-1)finish(1);
                        else begin polls<=polls+1'b1;timer<=POLL_GAP-1;state<=POLL_GAP_WAIT;end
                    end else if((engine_data&8'hbc)!=0)finish(6);
                    else begin security_next<=poll_next;state<=SECURITY_START;end
                end
                POLL_GAP_WAIT:if(timer==0)state<=saving?POLL_START:STATUS_START;else timer<=timer-1'b1;
                ERASE_VERIFY_START:begin compare_bad<=0;issue(2,base,4096,ERASE_VERIFY_RX);end
                ERASE_VERIFY_RX:if(engine_valid && engine_take)begin
                    if(engine_data!=8'hff)compare_bad<=1;if(engine_last)state<=ERASE_VERIFY_CHECK;
                end
                ERASE_VERIFY_CHECK:if(compare_bad)finish(10);else begin write_phase<=1;state<=WREN_START;end
                BODY_VERIFY_START:begin compare_bad<=0;index<=0;issue(2,base,64,BODY_VERIFY_RX);end
                BODY_VERIFY_RX:if(engine_valid && engine_take)begin
                    if(engine_data!=encoded)compare_bad<=1;
                    if(engine_last)state<=BODY_VERIFY_CHECK;else index<=index+1'b1;
                end
                BODY_VERIFY_CHECK:if(compare_bad)finish(11);else begin write_phase<=2;state<=WREN_START;end
                VERIFY_RECORD:begin commit_part<=0;verify_record<=1;state<=DEC_START;end
                SAVE_COMPLETE:begin
                    saved_valid<=1;saved_source<=slot?2:1;saved_bank<=snapshot;
                    saved_sequence<=candidate_sequence;saved_epoch<=snapshot_epoch;finish(0);
                end
                default:finish(5);
            endcase
            if(engine_done && engine_error && state!=CMD && state!=IDLE)finish(5);
            if(panel_reset)begin pending_panel<=1;calibration_ready<=0;end
        end
    end
endmodule
