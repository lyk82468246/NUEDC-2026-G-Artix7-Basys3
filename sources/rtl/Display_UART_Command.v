`timescale 1ns/1ps
// One right-aligned ASCII command, without terminators. Always append exactly
// three FF bytes. done includes the final STOP bit and the configurable gap.
// No FIFO: input payload must remain stable until in_valid && in_ready.
module Display_UART_Command #(
    parameter integer CLK_FREQ_HZ=100_000_000,BAUD_RATE=115200,
    parameter integer COMMAND_GAP_CYCLES=10000,PAGE_GAP_CYCLES=5_000_000
)(
    input wire clk,rst,in_valid,output wire in_ready,
    input wire [511:0] command,input wire [6:0] length,input wire is_page,
    output wire uart_tx,tx_idle,output reg done
);
    localparam IDLE=0,SEND=1,DRAIN=2,GAP=3;
    reg [1:0] state;
    reg [511:0] payload;
    reg [6:0] size,index;
    reg page;
    reg [31:0] gap_count;
    wire uart_busy;
    wire start=state==SEND && !uart_busy && !rst;
    wire [7:0] data=(index<size)?payload[(size-1-index)*8+:8]:8'hff;
    wire [31:0] gap_limit=page?PAGE_GAP_CYCLES:COMMAND_GAP_CYCLES;
    assign in_ready=!rst && state==IDLE;
    assign tx_idle=!uart_busy && state==IDLE;
    UART_Tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.BAUD_RATE(BAUD_RATE)) u_uart(
        .clk(clk),.rst(rst),.start(start),.data(data),.tx(uart_tx),.busy(uart_busy));
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;payload<=0;size<=0;index<=0;page<=0;gap_count<=0;done<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(in_valid && in_ready) begin
                    payload<=command;size<=length;index<=0;page<=is_page;state<=SEND;
                end
                SEND:if(start) begin
                    if(index==size+2) state<=DRAIN;else index<=index+1'b1;
                end
                DRAIN:if(!uart_busy) begin gap_count<=0;state<=GAP;end
                GAP:if(gap_limit==0 || gap_count>=gap_limit-1) begin done<=1;state<=IDLE;end
                    else gap_count<=gap_count+1'b1;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
