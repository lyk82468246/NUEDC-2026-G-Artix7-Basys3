`timescale 1ns/1ps
module tb_display_alignment;
    localparam N=8192,W=240;
    reg clk=0,rst=1,start=0,cycles=0,source_valid=1,ready=0;
    always #5 clk=~clk;
    reg [11:0] bin;
    wire input_ready,ren,axis,pv,done,locked,clamped,plotvalid;
    wire [12:0] addr;
    reg signed [15:0] data;
    reg signed [15:0] mem[0:N-1];
    wire [15:0] amax,index;
    wire [7:0] y;
    wire [31:0] refined;
    Display_Wave_Renderer #(.ENABLE_ALIGNMENT(1)) dut(
        .clk(clk),.rst(rst),.in_valid(start),.in_ready(input_ready),
        .signal_valid(source_valid),.three_cycles(cycles),.fundamental_bin(bin),.frame_id(32'd1),
        .rd_en(ren),.rd_addr(addr),.rd_data(data),.axis_valid(axis),.amax_raw(amax),
        .alignment_locked(locked),.refined_bin_q20(refined),
        .plot_valid(plotvalid),.window_clamped(clamped),.pixel_valid(pv),.pixel_ready(ready),
        .pixel_index(index),.pixel_y(y),.frame_id_out(),.done(done),.busy());
    always @(posedge clk)if(ren)begin
        assert(addr<N)else $fatal(1,"Address outside frozen frame");
        data<=mem[addr];
    end
    function real abs_real(input real x);abs_real=x<0?-x:x;endfunction
    integer ticks=0;
    always @(negedge clk)begin ticks=ticks+1;ready=(ticks%7!=0 && ticks%11!=0);end
    reg stalled=0;reg [23:0] held;
    always @(posedge clk)begin
        if(stalled)assert(pv && {index,y}==held)else $fatal(1,"Pixel changed under backpressure");
        stalled<=!rst && pv && !ready;held<={index,y};
    end
    task run_case(input real actual_bin,input real phase,input real base,input real harmonic,
                  input integer order,input bit three,input bit expect_lock);
        real p,v,estimated,phase_error,expected_start;
        longint signed q,a,b,frac,s,mag,expected_y;
        integer i,seen,rawmax,held_origin,held_span;
        begin
            rawmax=0;cycles=three;bin=$rtoi(actual_bin+0.5);
            for(i=0;i<N;i=i+1)begin
                p=6.283185307179586*actual_bin*i/N+phase;
                v=base*$sin(p)+harmonic*$sin(order*p+0.7)+base*0.2*$sin(3*p-0.4);
                mem[i]=$rtoi(v);
                if((mem[i]<0?-mem[i]:mem[i])>rawmax)rawmax=mem[i]<0?-mem[i]:mem[i];
            end
            wait(input_ready);@(negedge clk);start=1;@(negedge clk);start=0;
            wait(axis);@(negedge clk);
            assert(amax==rawmax && locked==expect_lock)else
                $fatal(1,"Lock/amax mismatch bin=%f phase=%f locked=%b max=%d/%d",actual_bin,phase,locked,amax,rawmax);
            held_origin=dut.origin_q12;held_span=dut.span_q12;
            if(expect_lock)begin
                estimated=$itor(refined)/1048576.0;
                assert(abs_real(estimated-actual_bin)<0.008)else
                    $fatal(1,"Fine bin=%f actual=%f",estimated,actual_bin);
                p=6.283185307179586*actual_bin*held_origin/(4096.0*N)+phase;
                phase_error=p-6.283185307179586*$floor(p/6.283185307179586+0.5);
                assert(abs_real(phase_error)<0.012)else $fatal(1,"Trigger phase error=%f",phase_error);
                expected_start=N/actual_bin*(three?3.0:1.0)*4096.0;
                assert(abs_real(held_span-expected_start)<expected_start*0.0005+4)else $fatal(1,"Period error");
            end
            seen=0;
            while(seen<W)begin
                @(posedge clk);
                if(pv && ready)begin
                    assert(index==seen)else $fatal(1,"Pixel index");
                    q=expect_lock?held_origin+(64'(seen)*held_span)/(W-1):
                        (64'(seen)*N*(three?3:1)*4096)/((W-1)*bin);
                    if(q>(N-1)*4096)q=(N-1)*4096;
                    a=q/4096;frac=q%4096;b=a==N-1?a:a+1;
                    s=(64'(mem[a])*4096+(64'(mem[b])-mem[a])*frac)>>>12;
                    mag=s<0?-s:s;expected_y=(mag*79+rawmax/2)/rawmax;
                    expected_y=s<0?80-expected_y:80+expected_y;
                    assert(y==expected_y)else $fatal(1,"Composite raw pixel %d got=%d expected=%d",seen,y,expected_y);
                    seen=seen+1;
                end
            end
            @(negedge clk);wait(input_ready);
            assert(!clamped)else $fatal(1,"Unexpected frame clamp");
            $display("case PASS bin=%f phase=%f harmonics=%0d three=%b lock=%b",actual_bin,phase,order,three,expect_lock);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        run_case(20.0,0.0,1000,2400,17,0,1);
        run_case(20.37,1.7,1000,2400,17,1,1);
        run_case(20.37,4.6,1000,2400,17,1,1);
        run_case(200.4,5.9,1000,1600,5,0,1);
        run_case(999.7,2.8,2000,1300,2,1,1);
        run_case(20.2,3.1,50,5000,17,1,1);
        // No actual selected fundamental: phase lock must fail, not manufacture a sine.
        run_case(20.0,0.9,0,4000,17,0,0);
        // Interrupt the serial estimator, not merely the legacy pixel path.
        @(negedge clk);start=1;@(negedge clk);start=0;
        wait(dut.g_align.u_align.state==13);
        @(negedge clk);rst=1;repeat(3)@(negedge clk);
        assert(input_ready==0 && !pv && !locked)else $fatal(1,"Reset did not cancel alignment");
        rst=0;@(negedge clk);assert(input_ready)else $fatal(1,"Reset recovery");
        $display("PASS: fundamental phase/period, off-grid and strong harmonics, exact original-frame pixels, backpressure, confidence fallback");
        $finish;
    end
    initial begin #100000000;$fatal(1,"Alignment timeout state=%d",dut.state);end
endmodule
