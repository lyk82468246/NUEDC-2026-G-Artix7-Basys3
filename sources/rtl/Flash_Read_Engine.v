`timescale 1ns/1ps
// Strictly READ ONLY. No arbitrary opcode, WREN, erase or program interface.
// kind 0=9F JEDEC ID (3B), 1=05 status (1B), 2=03 read (length bytes).
// kind/length/address are snapshotted at acceptance. Unknown physical models
// must first be identified; production partition/profile approval is separate.
module Flash_Read_Engine #(
    parameter integer HALF_PERIOD=4,CS_HIGH_CYCLES=8
)(
    input wire clk,por,input wire cmd_valid,output wire cmd_ready,
    input wire [1:0] cmd_kind,input wire [23:0] cmd_address,input wire [15:0] cmd_length,
    output reg data_valid,input wire data_ready,output reg [7:0] data,output reg data_last,
    output reg busy,done,error,
    output wire cs_n,sck,mosi,input wire miso
);
    localparam IDLE=0,HEADER=1,HEADER_WAIT=2,READ=3,READ_WAIT=4,DRAIN=5;
    reg [2:0] state;
    reg [1:0] kind,header_index;
    reg [23:0] address;
    reg [15:0] remaining;
    wire byte_ready,byte_valid;
    wire [7:0] received;
    reg [7:0] outgoing;
    wire accept_rx=state==HEADER_WAIT || (state==READ_WAIT && !data_valid);
    always @*begin
        outgoing=0;
        if(state==HEADER)case(header_index)
            0:outgoing=(kind==0)?8'h9f:((kind==1)?8'h05:8'h03);
            1:outgoing=address[23:16];2:outgoing=address[15:8];3:outgoing=address[7:0];
        endcase
    end
    Flash_SPI_Byte #(.HALF_PERIOD(HALF_PERIOD),.CS_HIGH_CYCLES(CS_HIGH_CYCLES)) u_byte(
        .clk(clk),.por(por),.req_valid(state==HEADER || (state==READ && !data_valid)),
        .req_ready(byte_ready),.req_data(outgoing),.req_last(state==READ && remaining==1),
        .rsp_valid(byte_valid),.rsp_ready(accept_rx),.rsp_data(received),
        .cs_n(cs_n),.sck(sck),.mosi(mosi),.miso(miso));
    assign cmd_ready=!por && state==IDLE && byte_ready;
    always @(posedge clk)begin
        if(por)begin
            state<=IDLE;kind<=0;header_index<=0;address<=0;remaining<=0;
            data_valid<=0;data<=0;data_last<=0;busy<=0;done<=0;error<=0;
        end else begin
            done<=0;
            if(data_valid && data_ready)data_valid<=0;
            case(state)
                IDLE:if(cmd_valid && cmd_ready)begin
                    error<=0;data_last<=0;header_index<=0;kind<=cmd_kind;address<=cmd_address;
                    remaining<=cmd_kind==0?16'd3:(cmd_kind==1?16'd1:cmd_length);
                    if(cmd_kind==3 || (cmd_kind==2 && (cmd_length==0 ||
                        {1'b0,cmd_address}+{9'd0,cmd_length}>25'h1000000)))begin
                        done<=1;error<=1;
                    end else begin busy<=1;state<=HEADER;end
                end
                HEADER:if(byte_ready)state<=HEADER_WAIT;
                HEADER_WAIT:if(byte_valid)begin
                    if(kind!=2 || header_index==3)state<=READ;
                    else begin header_index<=header_index+1'b1;state<=HEADER;end
                end
                READ:if(byte_ready && !data_valid)state<=READ_WAIT;
                READ_WAIT:if(byte_valid && accept_rx)begin
                    data<=received;data_valid<=1;data_last<=remaining==1;
                    if(remaining==1)state<=DRAIN;
                    else begin remaining<=remaining-1'b1;state<=READ;end
                end
                DRAIN:if(data_valid && data_ready)begin busy<=0;done<=1;state<=IDLE;end
                default:begin error<=1;busy<=0;state<=IDLE;end
            endcase
        end
    end
endmodule
