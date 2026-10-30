`timescale 1ns/1ps
// External restore must wait for the entire packet, and a simultaneous sample
// must keep its original epoch/bank. Blocked VIO toggles must never replay.
module tb_runtime_restore_atomic;
    reg clk=0,rst=1,req=0,sample=0,restore=0,blocked=0,packet=0;
    always #5 clk=~clk;
    reg [96:0] bank={1'b1,32'd131072,32'd131072,32'd131072};
    wire ready,ack,done,rejected;
    wire [31:0] epoch,result_epoch,vpp,active;
    Runtime_Calibration #(.EXTERNAL_BANK(1),.DEFAULT_ENABLED(1),
        .DEFAULT_VPP_GAIN(65536),.DEFAULT_RMS_GAIN(65536),.DEFAULT_FFT_GAIN(65536)) dut(
        .clk(clk),.rst(rst),.request_toggle(req),.staging_valid(1'b1),
        .staging_vpp_gain(32'd196608),.staging_rms_gain(32'd196608),.staging_fft_gain(32'd196608),
        .sample_valid(sample),.signal_valid(1'b1),.vpp_raw(17'd100),.rms_raw(16'd50),.fft_raw(32'd20),
        .ack_toggle(ack),.epoch(epoch),.result_epoch(result_epoch),.result_count(),
        .active_vpp_gain(active),.active_rms_gain(),.active_fft_gain(),.active_valid(),
        .vpp_uv(vpp),.rms_uv(),.peak_uv(),.valid(),.overflow(),.busy(),.done(done),.overrun(),
        .restore_valid(restore),.restore_bank(bank),.restore_ready(ready),
        .request_block(blocked),.packet_busy(packet),.commit_rejected(rejected));
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(5)@(negedge clk);
        packet=1;restore=1;req=1;
        repeat(6)@(negedge clk);
        assert(!ready && epoch==0 && ack==0)else $fatal(1,"Packet did not defer bank change");
        // Storage owns the bank; reject an old staged apply while blocked.
        blocked=1;repeat(4)@(negedge clk);
        assert(ack==1 && rejected)else $fatal(1,"Blocked toggle not rejected");
        packet=0;sample=1;@(negedge clk);sample=0;
        wait(done);@(negedge clk);
        assert(result_epoch==0 && vpp==100)else $fatal(1,"Restore mixed into old packet");
        wait(epoch==1);@(negedge clk);restore=0;blocked=0;
        repeat(5)@(negedge clk);
        assert(epoch==1 && active==131072)else $fatal(1,"Old VIO toggle replayed after restore");
        sample=1;@(negedge clk);sample=0;wait(done);@(negedge clk);
        assert(result_epoch==1 && vpp==200)else $fatal(1,"Next packet missed restored bank");
        $display("PASS: external restore packet boundary, sample priority, atomic epoch, blocked VIO no replay");$finish;
    end
    initial begin #10000;$fatal(1,"Restore contract timeout");end
endmodule

module tb_flash_command_guard;
    reg clk=0,por=1,start=0,verified=0;always #5 clk=~clk;
    reg [2:0] kind;
    reg [23:0] address;
    reg [15:0] count;
    wire ready,done,error,cs;
    Flash_Command_Engine #(.HALF_PERIOD(2)) dut(.clk(clk),.por(por),.verified(verified),
        .cmd_valid(start),.cmd_ready(ready),.cmd_kind(kind),.cmd_address(address),.cmd_length(count),
        .write_valid(1'b1),.write_ready(),.write_data(8'd0),.data_valid(),.data_ready(1'b1),.data(),.data_last(),
        .done(done),.error(error),.busy(),.cs_n(cs),.sck(),.mosi(),.miso(1'b1));
    always @(posedge clk)if(!por)assert(cs)else $fatal(1,"Rejected descriptor reached flash pins");
    task reject(input [2:0] op,input [23:0] addr,input [15:0] length);
        begin
            wait(ready);@(negedge clk);kind=op;address=addr;count=length;start=1;
            @(negedge clk);start=0;assert(done && error && cs)else $fatal(1,"Guard did not reject %d/%h/%d",op,addr,length);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);por=0;
        reject(3,24'h3e0000,0); // even WREN requires verified profile
        verified=1;
        reject(4,0,1);reject(5,24'h3df000,0);reject(5,24'h3e0001,0);
        reject(4,24'h3efff0,32);reject(4,24'h3e0000,0);reject(4,24'h3e0000,257);
        reject(4,24'hffffff,1);reject(5,24'h400000,0);reject(7,24'h3e0000,0);
        $display("PASS: lower-level write address/page/profile/opcode guards; no CS assertion on rejected descriptors");$finish;
    end
    initial begin #100000;$fatal(1,"Command guard timeout");end
endmodule
module tb_calibration_encoder;
    reg clk=0,por=1,start=0;always #5 clk=~clk;
    wire ready,valid;
    reg [6:0] address=0;
    wire [7:0] data;
    reg [7:0] golden[0:159];
    Calibration_Record_Encoder dut(.clk(clk),.por(por),.in_valid(start),.in_ready(ready),
        .bank({1'b1,32'd3600000,32'd3750000,32'd4200}),.record_sequence(32'd0),.saved_epoch(32'd12),
        .out_valid(valid),.out_ready(1'b0),.rd_addr(address),.rd_data(data));
    integer i;
    initial begin
        $readmemh("flash_valid.mem",golden);
        repeat(5)@(negedge clk);por=0;wait(ready);@(negedge clk);start=1;@(negedge clk);start=0;
        wait(valid);
        for(i=0;i<80;i=i+1)begin
            @(negedge clk);address=i;repeat(2)@(negedge clk);
            assert(data==golden[80+i])else $fatal(1,"Python/RTL record byte %d got=%h expected=%h",i,data,golden[80+i]);
        end
        $display("PASS: encoder 80 bytes including both CRCs exactly match Python format-1 golden");$finish;
    end
    initial begin #100000;$fatal(1,"Encoder timeout");end
endmodule
