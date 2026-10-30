`timescale 1ns/1ps
// Format-1 decoder: 64 body bytes then 16 commit bytes, little endian.
// Physical reader fetches the commit from slot+256, NOT immediately after body.
// CRC-32/ISO-HDLC: reflected EDB88320, initial/final XOR FFFFFFFF.
// Serial CRC consumes eight cycles per covered byte; backpressure is required.
module Calibration_Record_Decoder(
    input wire clk,por,in_valid,output wire in_ready,
    input wire byte_valid,output wire byte_ready,input wire [7:0] byte_data,
    output reg out_valid,input wire out_ready,output reg record_valid,
    output reg [31:0] record_sequence,saved_epoch,vpp_gain,rms_gain,fft_gain,
    output reg enabled
);
    localparam IDLE=0,BYTE=1,CRC=2,NEXT=3,CHECK_BODY=4,CHECK_COMMIT=5,RESULT=6;
    reg [2:0] state,bit_index;
    reg [6:0] index;
    reg [31:0] word,crc,body_crc,commit_crc,expected_body_crc,expected_commit_crc;
    reg [31:0] commit_sequence,commit_body_crc;
    reg bad;
    wire [31:0] assembled={byte_data,word[31:8]};
    wire [31:0] crc_next=crc[0]?(crc>>1)^32'hedb88320:(crc>>1);
    assign in_ready=!por && state==IDLE && !out_valid;
    assign byte_ready=!por && state==BYTE;
    always @(posedge clk)begin
        if(por)begin
            state<=IDLE;index<=0;bit_index<=0;word<=0;crc<=32'hffffffff;
            body_crc<=0;commit_crc<=0;expected_body_crc<=0;expected_commit_crc<=0;
            commit_sequence<=0;commit_body_crc<=0;bad<=0;out_valid<=0;record_valid<=0;
            record_sequence<=0;saved_epoch<=0;vpp_gain<=0;rms_gain<=0;fft_gain<=0;enabled<=0;
        end else case(state)
            IDLE:if(in_valid && in_ready)begin
                index<=0;word<=0;crc<=32'hffffffff;bad<=0;record_valid<=0;state<=BYTE;
            end
            BYTE:if(byte_valid && byte_ready)begin
                word<=assembled;
                if(index[1:0]==3)case(index)
                    3:if(assembled!=32'h4c414347)bad<=1; // GCAL
                    7:if(assembled!=32'h00400001)bad<=1; // length=64, format=1
                    11:record_sequence<=assembled;
                    15:if(assembled!=32'h00010001)bad<=1; // uV/raw Q16.16, FFT peak
                    19:begin enabled<=assembled[0];if(assembled[31:1]!=0)bad<=1;end
                    23:vpp_gain<=assembled;27:rms_gain<=assembled;31:fft_gain<=assembled;
                    35:saved_epoch<=assembled;
                    39,43,47,51,55,63:if(assembled!=0)bad<=1;
                    59:expected_body_crc<=assembled;
                    67:if(assembled!=32'h54494d43)bad<=1; // CMIT
                    71:commit_sequence<=assembled;
                    75:commit_body_crc<=assembled;
                    79:expected_commit_crc<=assembled;
                endcase
                if(index<56 || (index>=64 && index<76))begin
                    crc<=(index==64?32'hffffffff:crc)^{24'd0,byte_data};
                    bit_index<=0;state<=CRC;
                end else state<=NEXT;
            end
            CRC:begin
                crc<=crc_next;
                if(bit_index==7)begin
                    if(index==55)body_crc<=~crc_next;
                    if(index==75)commit_crc<=~crc_next;
                    state<=NEXT;
                end else bit_index<=bit_index+1'b1;
            end
            NEXT:if(index==79)state<=CHECK_BODY;
                else begin index<=index+1'b1;state<=BYTE;end
            CHECK_BODY:begin
                if(body_crc!=expected_body_crc || vpp_gain==0 || rms_gain==0 || fft_gain==0)bad<=1;
                state<=CHECK_COMMIT;
            end
            CHECK_COMMIT:begin
                if(commit_crc!=expected_commit_crc || commit_sequence!=record_sequence ||
                    commit_body_crc!=expected_body_crc)bad<=1;
                state<=RESULT;
            end
            RESULT:begin
                out_valid<=1;record_valid<=!bad;
                if(out_valid && out_ready)begin out_valid<=0;state<=IDLE;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
