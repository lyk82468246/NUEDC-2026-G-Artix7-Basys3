`timescale 1ns/1ps
module tb_run_controller;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, ready=0, single=1, start=0, cyc=0, left=0, right=0;
    reg fs=0,mv=0,finished=1,fault=0;
    reg [3:0] switches=0;
    wire ce,release_frame,fresh,sm,three;
    wire [1:0] mode,view;
    wire [31:0] frame_id,latency;
    wire [3:0] error;
    wire [2:0] state;
    Run_Controller #(.TIMEOUT_CYCLES(100)) dut(
        .clk(clk),.rst(rst),.controls_ready(ready),.mode_switches(switches),
        .single_request(single),.start_pulse(start),.cycle_pulse(cyc),
        .left_pulse(left),.right_pulse(right),.frame_start(fs),
        .measurement_valid(mv),.packet_finished(finished),.acquisition_fault(fault),
        .capture_enable(ce),.frame_release(release_frame),.mode_active(mode),
        .single_active(sm),.three_cycles_active(three),.view_active(view),
        .frame_id(frame_id),.result_fresh(fresh),.error_code(error),
        .latency_cycles(latency),.state_debug(state));
    task tick; begin @(negedge clk); end endtask
    task request; begin start=1; tick(); start=0; tick(); end endtask
    task capture; begin fs=1; tick(); fs=0; tick(); end endtask
    task packet; begin
        finished=0; mv=1; tick(); mv=0; tick();
        assert(fresh && !release_frame) else $fatal(1,"Result or ownership broken");
        repeat(4) tick();
        assert(!release_frame) else $fatal(1,"Released before last stop bit");
        finished=1; tick(); tick();
    end endtask
    integer i;
    reg [1:0] expected, saved;
    initial begin
        repeat(4) tick(); rst=0; ready=1;
        repeat(5) tick(); assert(!ce && frame_id==0) else $fatal(1,"Single boot captured");
        for(i=0;i<16;i=i+1) begin
            switches=i; request();
            expected=(i&8)?2:((i&4)?1:((i&2)?0:((i&1)?3:0)));
            assert(ce && mode==expected && sm) else $fatal(1,"Priority mask %x mode %d",i,mode);
            saved=mode; capture();
            switches=~i;
            repeat(3) tick();
            assert(mode==saved && !release_frame && !ce) else $fatal(1,"Mixed mode/stale release");
            packet();
            repeat(4) tick();
            assert(!ce) else $fatal(1,"Single mode retriggered");
        end
        assert(frame_id==16) else $fatal(1,"Wrong frame count");
        // A request queued during RUN must survive until the next safe boundary.
        request(); capture(); start=1; cyc=1; right=1; tick(); start=0;cyc=0;right=0;
        assert(!three && view==0) else $fatal(1,"Active options mutated");
        packet(); tick();
        assert(ce && three && view==1 && frame_id==18) else $fatal(1,"Queued request/options lost");
        capture(); packet();
        // No-signal deadline: no frame starts, retry remains user controlled.
        request(); repeat(105) tick();
        assert(state==0 && error==1 && !fresh) else $fatal(1,"Arm timeout failed");
        // Stale packet_finished must NOT recover a timed-out live consumer.
        request(); capture(); repeat(105) tick();
        assert(state==4 && !release_frame) else $fatal(1,"Unsafe fault release");
        mv=1; finished=0; tick(); mv=0; tick(); finished=1; tick(); tick();
        assert(state==0) else $fatal(1,"Late packet did not retire safely");
        single=0; tick(); tick(); assert(ce) else $fatal(1,"Continuous did not arm");
        $display("PASS: tb_run_controller priority16, single, queued request, stale release, deadlines");
        $finish;
    end
    initial begin #100000; $fatal(1,"Watchdog"); end
endmodule
