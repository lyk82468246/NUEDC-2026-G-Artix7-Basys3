`timescale 1ns/1ps
module tb_measurement_debug_snapshot;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,commit=0,sig=1,request=0;
    reg [16:0] pp=17'h1ffff;
    reg [15:0] rms=16'hffff;
    reg [31:0] mag=32'h80000001,id=1;
    reg [11:0] bin=100;
    reg [1:0] count=3;
    reg [35:0] bin_values={12'd400,12'd300,12'd100};
    reg [95:0] mags={32'hffffffff,32'h80000002,32'h80000001};
    reg present=1;
    wire valid,ack,enabled,rc_done,rc_busy;
    wire [31:0] epoch,result_epoch,rc_count;
    wire [16:0] outpp;wire [15:0] outrms;
    wire [31:0] outmag,outid,outepoch;
    wire [11:0] outbin;wire [1:0] outcount;
    wire [35:0] outbins;wire [95:0] outmags;wire [7:0] metadata;
    Measurement_Debug_Snapshot dut(.clk(clk),.rst(rst),.commit(commit),.signal_valid(sig),
        .vpp_raw(pp),.rms_raw(rms),.fundamental_raw(mag),.fundamental_bin(bin),
        .component_count(count),.component_bins(bin_values),.component_magnitudes(mags),
        .frame_id(id),.calibration_epoch(epoch),.calibration_enabled(enabled),
        .calibration_present(present),.mode(2'd1),.single_mode(1'b0),.three_cycles(1'b1),
        .measurement_valid_out(valid),.vpp_out(outpp),.rms_out(outrms),
        .fundamental_out(outmag),.fundamental_bin_out(outbin),.component_count_out(outcount),
        .component_bins_out(outbins),.component_magnitudes_out(outmags),
        .frame_id_out(outid),.calibration_epoch_out(outepoch),.metadata_out(metadata));
    Runtime_Calibration rc(.clk(clk),.rst(rst),.request_toggle(request),.staging_valid(1'b1),
        .staging_vpp_gain(32'd65536),.staging_rms_gain(32'd65536),.staging_fft_gain(32'd65536),
        .sample_valid(commit),.signal_valid(sig),.vpp_raw(pp),.rms_raw(rms),.fft_raw(mag),
        .ack_toggle(ack),.epoch(epoch),.result_epoch(result_epoch),.result_count(rc_count),.active_valid(enabled),
        .busy(rc_busy),.done(rc_done));
    task tick;begin @(negedge clk);end endtask
    task sample;begin commit=1;tick();commit=0;end endtask
    initial begin
        repeat(3)tick();assert(!valid && outmags==0 && outid==0) else $fatal(1,"Reset");
        // Wait for reset-time VIO toggle rebasing before a NEW host request.
        rst=0;repeat(4)tick();request=1;wait(ack==1);tick();
        // Arrange a new bank request pending exactly at the sample edge.
        request=0;tick();tick();sample();
        assert(valid && outepoch==1 && result_epoch==1 && epoch==1)
            else $fatal(1,"Commit/sample epoch collision");
        assert(outpp==17'h1ffff && outrms==16'hffff && outmag==32'h80000001 &&
               outbins==bin_values && outmags==mags && outcount==3 && metadata==8'h4f)
            else $fatal(1,"Atomic fields or unsigned MSB lost");
        // Changing live inputs cannot alter the held debug packet.
        pp=1;rms=2;mag=3;id=2;bin_values=0;mags=0;tick();
        assert(!valid && outid==1 && outmags=={32'hffffffff,32'h80000002,32'h80000001})
            else $fatal(1,"Hold between commits");
        wait(rc_done);tick();wait(ack==0);tick();
        assert(epoch==2 && outepoch==1) else $fatal(1,"Bank update relabelled old snapshot");
        // 3 -> 1: unused slots clear even when inputs contain stale nonzero data.
        bin_values={12'd999,12'd888,12'd100};mags={32'hffffffff,32'hffffffff,32'd33};
        count=1;sample();
        assert(outcount==1 && outbins==36'd100 && outmags==96'd33 && outid==2 && outepoch==2)
            else $fatal(1,"Stale slots on 3-to-1");
        repeat(9)tick();
        count=2;id=32'hffffffff;sample();
        assert(outcount==2 && outbins=={12'd0,12'd888,12'd100} &&
               outmags=={32'd0,32'hffffffff,32'd33} && outid==32'hffffffff)
            else $fatal(1,"Two slots or frame-ID MSB");
        repeat(9)tick();
        id=0;sample();assert(outid==0 && outcount==2) else $fatal(1,"Frame ID wrap");
        repeat(9)tick();
        sig=0;count=3;sample();
        assert(valid && outcount==0 && outbins==0 && outmags==0 && outbin==0 && outmag==0 &&
               outpp==1 && outrms==2 && !metadata[0]) else $fatal(1,"Invalid packet not masked");
        tick();sig=1;present=0;count=0;sample();
        assert(outepoch==0 && metadata[2:1]==2'b01 && outcount==0 && outmags==0)
            else $fatal(1,"Static calibration without VIO lost its enabled flag");
        rst=1;tick();assert(!valid && outpp==0 && outmags==0 && metadata==0) else $fatal(1,"Reset active");
        $display("PASS: atomic debug snapshot widths/slots/invalid/reset/epoch collision");$finish;
    end
    initial begin #100000;$fatal(1,"Snapshot timeout");end
endmodule
