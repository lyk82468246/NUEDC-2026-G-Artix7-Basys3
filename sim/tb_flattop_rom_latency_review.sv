`timescale 1ns/1ps
// Real generated Block Memory Generator netlist, not the one-cycle mock.
// DOUBLE_ENABLE=0 deliberately REPRODUCES current stale-coefficient behavior.
// DOUBLE_ENABLE=1 verifies a proposed two-enable + capture sequencing fix;
// no production FFT RTL is modified by this review test.
module tb_flattop_rom_latency_review #(parameter integer DOUBLE_ENABLE=0);
    reg clk=0,en=0;reg [12:0] addr=0;wire signed [15:0] data;
    reg [15:0] expected[0:8191],consumed,previous=0;
    integer i,a;
    FlatTop_Window_ROM dut(.clk(clk),.en(en),.addr(addr),.data(data));
    always #5 clk=~clk;
    initial begin
        $readmemh("expected.mem",expected);#200; // allow unisim GSR startup
        for(i=0;i<8;i=i+1)begin
            a=512+i*768;
            @(negedge clk);en=1;addr=a;
            @(posedge clk);#1;
            @(negedge clk);en=DOUBLE_ENABLE;
            @(posedge clk);consumed=data;#1;
            if(DOUBLE_ENABLE)begin
                @(negedge clk);en=0;
                @(posedge clk);consumed=data;#1;
                assert(consumed===expected[a])else $fatal(1,"Proposed ROM sequence stale at %0d",a);
            end else begin
                assert(consumed===previous && consumed!==expected[a])
                    else $fatal(1,"Current ROM mismatch was not reproduced at %0d",a);
            end
            $display("ROM_DOUBLE_ENABLE=%0d address=%0d captured=%h correct=%h",DOUBLE_ENABLE,a,consumed,expected[a]);
            previous=expected[a];repeat(2)@(negedge clk);
        end
        $display("PASS: actual ROM DOUBLE_ENABLE=%0d; 0 reproduces stale request, 1 validates proposed sequencing",DOUBLE_ENABLE);
        $finish;
    end
    initial begin #10000;$fatal(1,"ROM review timeout");end
endmodule
module tb_flattop_rom_double_enable_review;
    tb_flattop_rom_latency_review #(.DOUBLE_ENABLE(1)) test();
endmodule
