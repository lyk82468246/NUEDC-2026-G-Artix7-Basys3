`timescale 1ns/1ps
// SPI x1 mode 0, all logic in clk domain. SCK is an OUTPUT, not an RTL clock.
// Reset must be power-on only; NEVER connect BtnC while a flash write is live.
// req_last deasserts CS after this byte; otherwise CS stays low between bytes.
module Flash_SPI_Byte #(
    parameter integer HALF_PERIOD=4,CS_HIGH_CYCLES=8
)(
    input wire clk,por,
    input wire req_valid,output wire req_ready,input wire [7:0] req_data,input wire req_last,
    output reg rsp_valid,input wire rsp_ready,output reg [7:0] rsp_data,
    output reg cs_n,sck,mosi,input wire miso
);
    localparam IDLE=0,RISE=1,FALL=2,CS_GAP=3;
    reg [1:0] state;
    reg [31:0] timer;
    reg [2:0] bit_index;
    reg [7:0] tx,rx;
    reg last_byte;
    assign req_ready=!por && state==IDLE && !rsp_valid;
    // synthesis translate_off
    initial if(HALF_PERIOD<2 || CS_HIGH_CYCLES<2)$fatal(1,"Unsafe SPI timing parameters");
    // synthesis translate_on
    always @(posedge clk)begin
        if(por)begin
            state<=CS_GAP;timer<=CS_HIGH_CYCLES-1;bit_index<=0;
            tx<=0;rx<=0;last_byte<=0;rsp_valid<=0;rsp_data<=0;
            cs_n<=1;sck<=0;mosi<=0;
        end else begin
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            case(state)
                IDLE:if(req_valid && req_ready)begin
                    tx<=req_data;rx<=0;last_byte<=req_last;bit_index<=7;
                    cs_n<=0;sck<=0;mosi<=req_data[7];timer<=HALF_PERIOD-1;state<=RISE;
                end
                RISE:if(timer!=0)timer<=timer-1'b1;else begin
                    sck<=1;rx<={rx[6:0],miso};timer<=HALF_PERIOD-1;state<=FALL;
                end
                FALL:if(timer!=0)timer<=timer-1'b1;else begin
                    sck<=0;
                    if(bit_index==0)begin
                        rsp_data<=rx;rsp_valid<=1;
                        if(last_byte)begin cs_n<=1;timer<=CS_HIGH_CYCLES-1;state<=CS_GAP;end
                        else state<=IDLE;
                    end else begin
                        bit_index<=bit_index-1'b1;tx<=tx<<1;mosi<=tx[6];
                        timer<=HALF_PERIOD-1;state<=RISE;
                    end
                end
                CS_GAP:if(timer!=0)timer<=timer-1'b1;else state<=IDLE;
                default:begin cs_n<=1;sck<=0;state<=CS_GAP;timer<=CS_HIGH_CYCLES-1;end
            endcase
        end
    end
endmodule
