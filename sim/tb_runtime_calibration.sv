`timescale 1ns/1ps
module tb_runtime_calibration;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,req=0,cv=0,sv=0,sig=1;
    reg [31:0] a=65536,b=131072,c=196608;
    reg [16:0] pp=100;reg [15:0] rms=20;reg [31:0] fft=30;
    wire ack,av,v,ov,busy,done,overrun;
    wire [31:0] ep,rep,count,ag,bg,cg,p,r,f;
    Runtime_Calibration dut(.clk(clk),.rst(rst),.request_toggle(req),.staging_valid(cv),
        .staging_vpp_gain(a),.staging_rms_gain(b),.staging_fft_gain(c),
        .sample_valid(sv),.signal_valid(sig),.vpp_raw(pp),.rms_raw(rms),.fft_raw(fft),
        .ack_toggle(ack),.epoch(ep),.result_epoch(rep),.result_count(count),
        .active_vpp_gain(ag),.active_rms_gain(bg),.active_fft_gain(cg),.active_valid(av),
        .vpp_uv(p),.rms_uv(r),.peak_uv(f),.valid(v),.overflow(ov),.busy(busy),.done(done),.overrun(overrun));
    task tick;begin @(negedge clk);end endtask
    task sample;begin sv=1;tick();sv=0;end endtask
    task finish_job;begin wait(done);tick();end endtask
    initial begin
        repeat(4)tick();rst=0;tick();sample();
        assert(done && !v && p==0 && count==1) else $fatal(1,"Reset not uncalibrated");
        cv=1;req=1;wait(ack==req);tick();
        assert(av && ep==1) else $fatal(1,"Bank commit");
        sample();a=262144;b=327680;c=393216;req=0; // request during active job
        finish_job();
        assert(v && !ov && p==100 && r==40 && f==90 && rep==1)
            else $fatal(1,"Snapshot or units");
        wait(ack==req);tick();assert(ep==2 && ag==262144) else $fatal(1,"Deferred commit");
        sample();finish_job();assert(p==400 && r==100 && f==180 && rep==2) else $fatal(1,"New gains");
        sig=0;sample();assert(done && !v && p==0 && r==0 && f==0) else $fatal(1,"No signal gate");sig=1;
        // Half-up rounding: 1 raw * 0.5 uV -> 1 uV.
        a=32768;b=32768;c=32768;req=1;wait(ack==req);tick();pp=1;rms=1;fft=1;
        sample();finish_job();assert(p==1 && r==1 && f==1) else $fatal(1,"Rounding");
        a=32'hffffffff;b=a;c=a;req=0;wait(ack==req);tick();fft=32'hffffffff;
        sample();finish_job();assert(ov && f==32'hffffffff) else $fatal(1,"Saturation");
        cv=0;req=1;wait(ack==req);tick();sample();
        assert(!av && !v && p==0) else $fatal(1,"Disable leaked old result");
        // Missing coeff disables entire bank; staging cannot enable itself.
        cv=1;a=0;req=0;wait(ack==req);tick();assert(!av) else $fatal(1,"Zero bank enabled");
        assert(!overrun) else $fatal(1,"Unexpected overrun");
        a=65536;b=65536;c=65536;req=1;wait(ack==req);tick();
        sample();sample();finish_job();
        assert(overrun) else $fatal(1,"Busy input was silently lost");
        rst=1;tick();rst=0;tick();
        assert(!overrun && !av && ep==0) else $fatal(1,"Reset did not invalidate bank");
        $display("PASS: runtime calibration atomic commit, snapshots, epochs, invalid gate, rounding and saturation");$finish;
    end
    initial begin #20000;$fatal(1,"Runtime calibration watchdog");end
endmodule
