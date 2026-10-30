`timescale 1ns/1ps
// P1 board diagnostic only. Does NOT drive Runtime_Calibration's active bank.
// Only 05/9F/03 reach the pins. Clock/POR are independent of BtnC/MMCM reset.
module Flash_Readonly_Probe(
    input wire clk,por,request_toggle,
    output wire cs_n,sck,mosi,input wire miso,
    output wire [31:0] status,output reg [23:0] jedec_id,
    output reg [31:0] record_sequence,saved_epoch,output reg [96:0] bank
);
    reg req1,req2,ack,initialized;
    reg valid_record;
    reg [1:0] source;
    reg [3:0] error;
    reg [7:0] last_status;
    wire [7:0] restored_status;
    wire ready,result_valid,store_busy,restored_valid;
    wire [23:0] restored_id;
    wire [31:0] restored_seq,restored_epoch;
    wire [96:0] restored_bank;
    wire [1:0] restored_source;
    wire [3:0] restored_error;
    wire reload=initialized && ready && req2!=ack;
    assign status={13'd0,last_status,initialized,ack,error,source,valid_record,ready,store_busy};
    Calibration_Flash_Restore #(.EXPECTED_JEDEC(24'hc22016)) u_restore(
        .clk(clk),.por(por),.reload_valid(reload),.reload_ready(ready),
        .out_valid(result_valid),.out_ready(1'b1),.record_valid(restored_valid),
        .bank(restored_bank),.record_sequence(restored_seq),.saved_epoch(restored_epoch),
        .source(restored_source),.error_code(restored_error),.jedec_id(restored_id),.status_register(restored_status),
        .busy(store_busy),.cs_n(cs_n),.sck(sck),.mosi(mosi),.miso(miso));
    always @(posedge clk)begin
        if(por)begin
            req1<=0;req2<=0;ack<=0;initialized<=0;valid_record<=0;source<=0;error<=0;
            jedec_id<=0;last_status<=0;record_sequence<=0;saved_epoch<=0;bank<=0;
        end else begin
            req1<=request_toggle;req2<=req1;
            if(result_valid)begin
                initialized<=1;ack<=req2;valid_record<=restored_valid;source<=restored_source;error<=restored_error;
                jedec_id<=restored_id;last_status<=restored_status;
                record_sequence<=restored_seq;saved_epoch<=restored_epoch;bank<=restored_bank;
            end
        end
    end
endmodule
