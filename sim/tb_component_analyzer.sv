`timescale 1ns/1ps
module tb_component_analyzer;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,toggle=0;
    reg [1:0] mode=0;
    wire [11:0] address;wire en,done,busy,consistent;
    reg [31:0] data=0,mem[0:4095],expected[0:6];
    wire [1:0] count;
    wire [35:0] bin_list;wire [95:0] magnitudes;
    wire [11:0] fundamental;wire [31:0] frequency,amplitude;
    Component_Analyzer dut(.clk(clk),.rst(rst),.frame_done_toggle(toggle),.mode(mode),
        .rd_addr(address),.rd_en(en),.rd_data(data),.component_count(count),
        .component_bins(bin_list),.component_magnitudes(magnitudes),.fundamental_bin(fundamental),
        .fundamental_hz(frequency),.fundamental_magnitude(amplitude),
        .harmonics_consistent(consistent),.result_valid(done),.busy(busy));
    always @(posedge clk) if(en) data<=mem[address];
    string names[0:6];
    integer c,k,idx,diff,cycles;
    reg [31:0] actual;
    task tick;begin @(negedge clk);end endtask
    task run_case;begin
        toggle=~toggle;cycles=0;tick();
        while(!done && cycles<40000) begin tick();cycles=cycles+1;end
        assert(done) else $fatal(1,"Analyzer timeout");
        tick();
    end endtask
    initial begin
        names[0]="A_10500_weak_fundamental";names[1]="A_upper_edge";
        names[2]="B_upper_edge";names[3]="B_off_bin";names[4]="B_two_components";
        names[5]="B_phase_zero";names[6]="B_phase_shift";
        repeat(5) tick();rst=0;repeat(4) tick();
        for(c=0;c<7;c=c+1) begin
            $readmemh($sformatf("../contest_reference/%s_mag.mem",names[c]),mem);
            $readmemh($sformatf("../contest_reference/%s_expected.mem",names[c]),expected);
            mode=(c<2)?0:1;run_case();
            assert(count==expected[0] && consistent) else $fatal(1,"Component count/consistency %s",names[c]);
            for(k=0;k<count;k=k+1) begin
                idx=bin_list[k*12 +: 12];diff=idx-expected[1+2*k];if(diff<0) diff=-diff;
                assert(diff<=1) else $fatal(1,"Peak bin %s k=%0d",names[c],k);
                actual=magnitudes[k*32 +: 32];
                assert(actual>=expected[2+2*k]-2 && actual<=expected[2+2*k]+2)
                    else $fatal(1,"Magnitude mismatch %s k=%0d",names[c],k);
            end
            assert(fundamental==bin_list[11:0] && frequency==fundamental*500 && amplitude==magnitudes[31:0])
                else $fatal(1,"Fundamental not lowest component");
        end
        // Reject an unrelated second peak; retain component table, no invented f1.
        for(k=0;k<4096;k=k+1)mem[k]=0;
        mem[21]=10000;mem[55]=5000;mode=1;run_case();
        assert(count==2 && !consistent && frequency==0) else $fatal(1,"Non-harmonic signal accepted");
        // No-signal result must clear all old components atomically.
        for(k=0;k<4096;k=k+1)mem[k]=0;
        run_case();assert(count==0 && bin_list==0 && magnitudes==0 && !consistent) else $fatal(1,"Stale components on silence");
        // Broadband noise must not become three arbitrary measured tones.
        for(k=0;k<4096;k=k+1)mem[k]=1000+(k*37)%300;
        run_case();assert(count==0 && frequency==0) else $fatal(1,"Noise accepted as signal");
        // Exclude strong mainlobes before calculating background, so an actual
        // weak fundamental ten times the floor is retained, not suppressed by
        // the much stronger harmonics' contribution to the mean.
        for(k=0;k<4096;k=k+1)mem[k]=1000;
        mem[20]=10000;mem[200]=1000000;mem[199]=990000;mem[201]=980000;mem[400]=500000;
        mode=0;run_case();
        assert(count==3 && fundamental==20 && amplitude==10000 && dut.noise_mean_raw==1000)
            else $fatal(1,"Strong lobes biased background or lost weak fundamental");
        // Wide accumulator and saturated threshold must not wrap at full scale.
        for(k=0;k<4096;k=k+1)mem[k]=32'hffffffff;
        mode=1;run_case();assert(count==0 && dut.noise_mean_raw==32'hffffffff)
            else $fatal(1,"Noise sum/division/threshold overflow");
        // Debug's largest harmonic order is 400, not a six-bit counter.
        for(k=0;k<4096;k=k+1)mem[k]=100;
        mem[10]=1000000;mem[4000]=500000;mode=3;run_case();
        assert(count==2 && consistent && fundamental==10 && frequency==5000 && bin_list[23:12]==4000)
            else $fatal(1,"Debug boundaries or high harmonic order");
        $display("PASS: tb_component_analyzer seven composite FFT fixtures, strong harmonics, off-bin, silence and inconsistent peaks");
        $finish;
    end
endmodule
