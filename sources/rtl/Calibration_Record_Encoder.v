`timescale 1ns/1ps
// Same format as calibration_record.py. Capture APPLIED bank, not VIO staging.
// 80-byte private buffer: body[0:63], separate-page commit[64:79].
// Serial CRC and synchronous buffer read; no multiplier or wide barrel shifter.
module Calibration_Record_Encoder(
    input wire clk,por,in_valid,output wire in_ready,
    input wire [96:0] bank,input wire [31:0] record_sequence,saved_epoch,
    output reg out_valid,input wire out_ready,
    input wire [6:0] rd_addr,output reg [7:0] rd_data
);
    localparam IDLE=0,FILL=1,CRC=2,NEXT=3,RESULT=4;
    reg [2:0] state,bit_index;
    reg [6:0] index;
    reg [96:0] snapshot;
    reg [31:0] seq,epoch,crc,body_crc,commit_crc;
    (* ram_style="block" *) reg [7:0] memory[0:79];
    reg [31:0] word;
    wire [7:0] value=word>>(index[1:0]*8);
    wire [31:0] crc_next=crc[0]?(crc>>1)^32'hedb88320:(crc>>1);
    assign in_ready=!por && state==IDLE && !out_valid;
    always @(posedge clk)rd_data<=memory[rd_addr];
    always @*begin
        word=0;
        case(index[6:2])
            0:word=32'h4c414347;1:word=32'h00400001;2:word=seq;3:word=32'h00010001;
            4:word={31'd0,snapshot[96]};5:word=snapshot[95:64];6:word=snapshot[63:32];
            7:word=snapshot[31:0];8:word=epoch;14:word=body_crc;
            16:word=32'h54494d43;17:word=seq;18:word=body_crc;19:word=commit_crc;
        endcase
    end
    always @(posedge clk)begin
        if(por)begin
            state<=IDLE;bit_index<=0;index<=0;snapshot<=0;seq<=0;epoch<=0;
            crc<=32'hffffffff;body_crc<=0;commit_crc<=0;out_valid<=0;
        end else case(state)
            IDLE:if(in_valid && in_ready)begin
                snapshot<=bank;seq<=record_sequence;epoch<=saved_epoch;index<=0;
                crc<=32'hffffffff;state<=FILL;
            end
            FILL:begin
                memory[index]<=value;
                if(index<56 || (index>=64 && index<76))begin
                    crc<=(index==64?32'hffffffff:crc)^{24'd0,value};bit_index<=0;state<=CRC;
                end else state<=NEXT;
            end
            CRC:begin
                crc<=crc_next;
                if(bit_index==7)begin
                    if(index==55)body_crc<=~crc_next;if(index==75)commit_crc<=~crc_next;state<=NEXT;
                end else bit_index<=bit_index+1'b1;
            end
            NEXT:if(index==79)state<=RESULT;else begin index<=index+1'b1;state<=FILL;end
            RESULT:begin out_valid<=1;if(out_valid && out_ready)begin out_valid<=0;state<=IDLE;end end
            default:state<=IDLE;
        endcase
    end
endmodule
