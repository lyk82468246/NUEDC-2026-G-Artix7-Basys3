`timescale 1ns/1ps
// Real analyzer FSM against independent one-tone expectations and explicit spur
// fixtures. FFT/ADC numeric generation is approximate; IP protocol is not tested.
module tb_single_tone_grid_review;
    reg clk=0,rst=1,toggle=0;always #5 clk=~clk;
    reg [1:0] mode=0;reg [31:0] data=0,mem[0:4095],expected[0:9];
    wire [11:0] address,fundamental;wire en,done,consistent;
    wire [1:0] count;wire [35:0] bin_values;wire [95:0] magnitudes;
    wire [31:0] frequency,amplitude;
    Component_Analyzer dut(.clk(clk),.rst(rst),.frame_done_toggle(toggle),.mode(mode),
        .rd_addr(address),.rd_en(en),.rd_data(data),.component_count(count),.component_bins(bin_values),
        .component_magnitudes(magnitudes),.fundamental_bin(fundamental),.fundamental_hz(frequency),
        .fundamental_magnitude(amplitude),.harmonics_consistent(consistent),.noise_mean_raw(),
        .result_valid(done),.busy());
    always @(posedge clk)if(en)data<=mem[address];
    integer c,k,guard,spur_valid=0;
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(4)@(negedge clk);
        for(c=0;c<246;c=c+1)begin
            $readmemh($sformatf("case_%03d.mem",c),mem);
            $readmemh($sformatf("case_%03d_expected.mem",c),expected);
            mode=expected[0];toggle=~toggle;guard=0;@(negedge clk);
            while(!done && guard<40000)begin @(negedge clk);guard++;end
            assert(done && count==expected[1] && consistent==expected[2] && fundamental==expected[3])
                else $fatal(1,"Grid case %0d count=%0d valid=%0d bin=%0d",c,count,consistent,fundamental);
            assert(frequency==expected[3]*500 && amplitude==(expected[2]?expected[7]:0))
                else $fatal(1,"Grid case %0d qualified outputs",c);
            for(k=0;k<3;k=k+1)begin
                assert(bin_values[k*12+:12]==expected[4+k] && magnitudes[k*32+:32]==expected[7+k])
                    else $fatal(1,"Grid case %0d raw candidate %0d",c,k);
            end
            if(c%3==2 && consistent)spur_valid++;
            @(negedge clk);
        end
        $display("PASS: 246 A/B grid cases; ideal and delayed-window tones all pass; fixed-spur valid cases=%0d/82",spur_valid);
        $finish;
    end
    initial begin #100000000;$fatal(1,"Grid timeout");end
endmodule
