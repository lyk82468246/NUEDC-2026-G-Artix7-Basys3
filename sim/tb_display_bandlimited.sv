`timescale 1ns/1ps
// Accuracy golden is the original continuous composite signal, NOT the RTL's
// linear segments or its coefficient table. Inputs are quantized ADC samples.
module tb_display_bandlimited;
    localparam N=8192,W=240;
    reg clk=0,rst=1,start=0,cycles=0,ready=0;
    always #5 clk=~clk;
    reg [11:0] bin;
    wire can_start,ren,axis,pv,done,locked,clamped;
    wire [12:0] addr;
    reg signed [15:0] data,mem[0:N-1];
    wire [15:0] amax,index;
    wire [7:0] y;
    Display_Wave_Renderer #(.ENABLE_ALIGNMENT(1),.BANDLIMITED(1)) dut(
        .clk(clk),.rst(rst),.in_valid(start),.in_ready(can_start),
        .signal_valid(1'b1),.three_cycles(cycles),.fundamental_bin(bin),.frame_id(32'd1),
        .rd_en(ren),.rd_addr(addr),.rd_data(data),.axis_valid(axis),.amax_raw(amax),
        .alignment_locked(locked),.refined_bin_q20(),.plot_valid(),.window_clamped(clamped),
        .pixel_valid(pv),.pixel_ready(ready),.pixel_index(index),.pixel_y(y),.done(done),.busy(),.frame_id_out());
    always @(posedge clk)if(ren)begin
        assert(addr<N)else $fatal(1,"Out of frame");data<=mem[addr];
    end
    integer ticks=0;
    always @(negedge clk)begin ticks=ticks+1;ready=ticks%13!=0;end
    real tone_bin,phase;
    bit composite;
    function real original(input real n);
        real p;
        begin
            p=6.283185307179586*tone_bin*n/N+phase;
            original=composite?(5000*$sin(p)+3000*$sin(3*p+0.7)+2000*$sin(5*p-0.4)):10000*$sin(p);
        end
    endfunction
    function real absolute(input real v);absolute=v<0?-v:v;endfunction
    task run_case(input real hz,input real initial_phase,input bit three,input bit harmonics);
        integer i,seen,expected_y;
        real coordinate,truth,error,max_error,rms_error;
        begin
            tone_bin=hz/500;phase=initial_phase;composite=harmonics;cycles=three;bin=$rtoi(tone_bin+0.5);
            for(i=0;i<N;i=i+1)mem[i]=$rtoi(original(i));
            wait(can_start);@(negedge clk);start=1;@(negedge clk);start=0;
            wait(axis);@(negedge clk);
            assert(locked && !clamped)else $fatal(1,"Alignment/guard failed");
            if(!composite)assert(amax>=9950 && amax<=10050)
                else $fatal(1,"Reconstructed extrema missing: amax=%d",amax);
            seen=0;max_error=0;rms_error=0;
            while(seen<W)begin
                @(posedge clk);
                if(pv && ready)begin
                    coordinate=$itor(dut.origin_q12)/4096.0+
                        $itor(seen)*dut.span_q12/(4096.0*(W-1));
                    truth=original(coordinate);
                    error=absolute($itor($signed(dut.interpolated_sample))-truth);
                    if(error>max_error)max_error=error;rms_error=rms_error+error*error;
                    expected_y=$rtoi(absolute(truth)*79/amax+0.5);
                    if(expected_y>79)expected_y=79;
                    expected_y=truth<0?80-expected_y:80+expected_y;
                    assert(absolute($itor(y)-expected_y)<=2)else
                        $fatal(1,"Pixel distortion f=%f p=%d got=%d expected=%d",hz,seen,y,expected_y);
                    assert(index==seen)else $fatal(1,"Pixel index");seen=seen+1;
                end
            end
            rms_error=$sqrt(rms_error/W);
            assert(max_error<100 && rms_error<45)else
                $fatal(1,"Interpolation error f=%f max=%f rms=%f",hz,max_error,rms_error);
            $display("case PASS f=%f three=%b composite=%b amax=%d max_error=%f rms_error=%f",hz,three,harmonics,amax,max_error,rms_error);
            @(negedge clk);wait(can_start);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        run_case(10000,0.1,0,0);
        run_case(100000,1.2,1,0);
        run_case(200000,2.1,0,0);
        run_case(409600,0.0,0,0); // exactly ten samples/cycle: no phase-fold shortcut
        run_case(500000,0.3,0,0);
        run_case(500000,3.4,1,0);
        run_case(100000,0.8,1,1); // true 100/300/500kHz composite; preserve harmonics
        $display("PASS: bandlimited interpolation against continuous sine/composite, high-band/coherent sampling, extrema and 240 pixels");
        $finish;
    end
    initial begin #100000000;$fatal(1,"Bandlimited renderer timeout state=%d",dut.state);end
endmodule
module tb_display_interpolator_contract;
    reg clk=0,rst=1,start=0,take=0;
    always #5 clk=~clk;
    reg [47:0] coordinate=0;
    wire ready,ren,valid,edge_hit,overflow;
    wire signed [15:0] result;
    wire [6:0] address;
    reg signed [15:0] data,memory[0:127];
    Display_Bandlimited_Interpolator #(.FRAME_LENGTH(128),.ADDR_WIDTH(7)) dut(
        .clk(clk),.rst(rst),.in_valid(start),.in_ready(ready),.coordinate(coordinate),
        .rd_en(ren),.rd_addr(address),.rd_data(data),.out_valid(valid),.out_ready(take),
        .sample(result),.edge_clamped(edge_hit),.overflow(overflow));
    always @(posedge clk)if(ren)data<=memory[address];
    task query(input [47:0] q,input integer expected,input bit edge_expected,input bit overflow_expected);
        begin
            wait(ready);@(negedge clk);coordinate=q;start=1;@(negedge clk);start=0;
            wait(valid);repeat(13)begin
                @(negedge clk);
                assert(valid && $signed(result)==expected && edge_hit==edge_expected && overflow==overflow_expected)
                    else $fatal(1,"Interpolator signed/clamp/stall contract result=%d expected=%d",result,expected);
            end
            take=1;@(negedge clk);take=0;wait(ready);
        end
    endtask
    integer i;
    initial begin
        repeat(5)@(negedge clk);rst=0;
        for(i=0;i<128;i=i+1)memory[i]=-32768;
        query((48'd16<<12)+505,-32768,0,0);
        for(i=0;i<128;i=i+1)memory[i]=32767;
        query((48'd16<<12)+3150,32767,0,0);
        for(i=0;i<128;i=i+1)memory[i]=0;memory[9]=10000;
        query((48'd9<<12)-1,10000,0,0); // fraction rounds into next integer
        for(i=0;i<128;i=i+1)memory[i]=5000;
        query(0,5000,1,0);
        // Drive each tap with the sign of its half-phase coefficient to force
        // an overshoot. Saturation must occur after the full signed sum.
        for(i=0;i<16;i=i+1)memory[16+i-7]=dut.u_coeff.rom[32*16+i][15]?-32768:32767;
        query((48'd16<<12)+2048,32767,0,1);
        for(i=0;i<16;i=i+1)memory[16+i-7]=dut.u_coeff.rom[32*16+i][15]?32767:-32768;
        query((48'd16<<12)+2048,-32768,0,1);
        @(negedge clk);coordinate=48'd16<<12;start=1;@(negedge clk);start=0;
        wait(dut.state==3);@(negedge clk);rst=1;repeat(3)@(negedge clk);
        assert(!valid && !ready)else $fatal(1,"Reset cancellation");rst=0;
        @(negedge clk);assert(ready)else $fatal(1,"Reset recovery");
        $display("PASS: interpolation signed full-scale, DC normalization, phase carry, edge clamp, saturation, output stall and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Interpolator contract timeout");end
endmodule
