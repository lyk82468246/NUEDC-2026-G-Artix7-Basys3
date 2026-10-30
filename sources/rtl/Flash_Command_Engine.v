`timescale 1ns/1ps
// MX25L3233F x1 command transport. No arbitrary opcode or status-register write.
// 0=RDID,1=RDSR,2=READ,3=WREN,4=PP,5=4KiB SE,6=RDSCUR. 7 is forbidden.
// Every modifying descriptor is range/page checked HERE, not just by its caller.
// verified must follow physical ID/SR/security checks; POR only, never BtnC.
module Flash_Command_Engine #(parameter integer HALF_PERIOD=4)(
    input wire clk,por,verified,input wire cmd_valid,output wire cmd_ready,
    input wire [2:0] cmd_kind,input wire [23:0] cmd_address,input wire [15:0] cmd_length,
    input wire write_valid,output wire write_ready,input wire [7:0] write_data,
    output reg data_valid,input wire data_ready,output reg [7:0] data,output reg data_last,
    output reg done,error,output wire busy,
    output wire cs_n,sck,mosi,input wire miso
);
    localparam IDLE=0,HEADER=1,HEADER_WAIT=2,READ=3,READ_WAIT=4,DRAIN=5,WRITE=6,WRITE_WAIT=7;
    reg [2:0] state,kind;
    reg [1:0] hindex;
    reg [23:0] address;
    reg [15:0] remaining;
    reg [7:0] outgoing;
    wire byte_ready,byte_valid;
    wire [7:0] received;
    wire address_header=(kind==2 || kind==4 || kind==5);
    wire header_last=(kind==3) || (kind==5 && hindex==3);
    wire [24:0] ending={1'b0,cmd_address}+{9'd0,cmd_length};
    wire [24:0] erase_end={1'b0,cmd_address}+25'd4096;
    wire modifying=cmd_kind==3 || cmd_kind==4 || cmd_kind==5;
    wire bad_write=modifying && (!verified ||
        (cmd_kind==4 && (cmd_length==0 || cmd_length>256 ||
            {1'b0,cmd_address[7:0]}+{1'b0,cmd_length}>17'd256 ||
            cmd_address<24'h3e0000 || ending>25'h0400000)) ||
        (cmd_kind==5 && (cmd_address[11:0]!=0 || cmd_address<24'h3e0000 || erase_end>25'h0400000)));
    wire receive_ready=state==HEADER_WAIT || state==WRITE_WAIT || (state==READ_WAIT && !data_valid);
    assign cmd_ready=!por && state==IDLE && byte_ready;
    assign write_ready=state==WRITE && byte_ready;
    assign busy=state!=IDLE;
    always @*begin
        outgoing=0;
        if(state==WRITE)outgoing=write_data;
        else if(state==HEADER)case(hindex)
            0:case(kind)
                0:outgoing=8'h9f;1:outgoing=8'h05;2:outgoing=8'h03;
                3:outgoing=8'h06;4:outgoing=8'h02;5:outgoing=8'h20;6:outgoing=8'h2b;
                default:outgoing=0;
            endcase
            1:outgoing=address[23:16];2:outgoing=address[15:8];3:outgoing=address[7:0];
        endcase
    end
    Flash_SPI_Byte #(.HALF_PERIOD(HALF_PERIOD)) u_byte(
        .clk(clk),.por(por),.req_valid(state==HEADER || (state==READ && !data_valid) || (state==WRITE && write_valid)),
        .req_ready(byte_ready),.req_data(outgoing),
        .req_last((state==HEADER && header_last) || ((state==READ || state==WRITE) && remaining==1)),
        .rsp_valid(byte_valid),.rsp_ready(receive_ready),.rsp_data(received),
        .cs_n(cs_n),.sck(sck),.mosi(mosi),.miso(miso));
    always @(posedge clk)begin
        if(por)begin
            state<=IDLE;kind<=0;hindex<=0;address<=0;remaining<=0;
            data_valid<=0;data<=0;data_last<=0;done<=0;error<=0;
        end else begin
            done<=0;if(data_valid && data_ready)data_valid<=0;
            case(state)
                IDLE:if(cmd_valid && cmd_ready)begin
                    kind<=cmd_kind;address<=cmd_address;hindex<=0;error<=0;
                    remaining<=cmd_kind==0?16'd3:((cmd_kind==1 || cmd_kind==6)?16'd1:cmd_length);
                    if(cmd_kind==7 || bad_write ||
                        (cmd_kind==2 && (cmd_length==0 || ending>25'h0400000)))begin error<=1;done<=1;end
                    else state<=HEADER;
                end
                HEADER:if(byte_ready)state<=HEADER_WAIT;
                HEADER_WAIT:if(byte_valid)begin
                    if(header_last)begin done<=1;state<=IDLE;end
                    else if(address_header && hindex!=3)begin hindex<=hindex+1'b1;state<=HEADER;end
                    else state<=kind==4?WRITE:READ;
                end
                READ:if(byte_ready && !data_valid)state<=READ_WAIT;
                READ_WAIT:if(byte_valid && receive_ready)begin
                    data<=received;data_valid<=1;data_last<=remaining==1;
                    if(remaining==1)state<=DRAIN;else begin remaining<=remaining-1'b1;state<=READ;end
                end
                DRAIN:if(data_valid && data_ready)begin done<=1;state<=IDLE;end
                WRITE:if(write_valid && write_ready)state<=WRITE_WAIT;
                WRITE_WAIT:if(byte_valid)begin
                    if(remaining==1)begin done<=1;state<=IDLE;end
                    else begin remaining<=remaining-1'b1;state<=WRITE;end
                end
                default:begin error<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
