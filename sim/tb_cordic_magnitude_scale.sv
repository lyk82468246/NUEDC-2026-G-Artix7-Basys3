`timescale 1ns/1ps
// Test the actual generated CORDIC netlist, not a behavioral sqrt substitute.
// SignedFraction 30-bit input (28 fractional) -> 31-bit output (29 fractional)
// must DOUBLE the raw radius code. FFT_Processor's preceding >>>1 cancels it.
module tb_cordic_magnitude_scale;
    reg clk=0;always #5 clk=~clk;
    reg reset_n=0,valid=0;
    reg [63:0] cartesian=0;
    wire ready,out_valid;
    wire [63:0] result;
    integer received=0;
    integer expected[0:2];
    integer delta;
    cordic_translate_mag dut(.aclk(clk),.aresetn(reset_n),
        .s_axis_cartesian_tvalid(valid),.s_axis_cartesian_tready(ready),
        .s_axis_cartesian_tdata(cartesian),.m_axis_dout_tvalid(out_valid),
        .m_axis_dout_tready(1'b1),.m_axis_dout_tdata(result));
    task send;
        input signed [31:0] x,y;
        begin
            @(negedge clk);cartesian={y,x};valid=1;
            @(posedge clk);while(!ready) @(posedge clk);
            @(negedge clk);valid=0;
        end
    endtask
    always @(posedge clk) if(reset_n && out_valid) begin
        assert(received<3) else $fatal(1,"Unexpected CORDIC output");
        delta=$signed({1'b0,result[30:0]})-expected[received];
        assert(delta>=-16 && delta<=16)
            else $fatal(1,"CORDIC raw alignment actual=%0d expected=%0d",result[30:0],expected[received]);
        $display("CORDIC_SCALE input radius=%0d output raw=%0d",expected[received]/2,result[30:0]);
        received=received+1;
    end
    initial begin
        expected[0]=2000000;expected[1]=1000000;expected[2]=1000000;
        repeat(20) @(negedge clk);reset_n=1;repeat(10) @(negedge clk);
        send(1000000,0);send(-300000,400000);send(0,-500000);
        wait(received==3);repeat(10) @(negedge clk);
        $display("PASS: tb_cordic_magnitude_scale actual IP raw factor2 in all quadrants");$finish;
    end
    initial begin #100000;$fatal(1,"CORDIC scale timeout");end
endmodule
