`timescale 1ns/1ps
// Real production wrapper + real generated ROM + deliberately stalled FFT sink.
// Verify every windowed input including the cycle TREADY returns after a stall.
module tb_fft_window_backpressure;
 reg clk=0,rst=1,toggle=0;always #5 clk=~clk;
 wire en;wire [12:0] addr;reg signed [15:0] data=0;
 reg signed [15:0] coefficients[0:8191];
 integer frame=0,n=0,total=0,stalls=0,guard;
 reg held=0,config_held=0;reg[31:0] held_data;reg held_last;reg[7:0] held_config;
 reg signed [31:0] product,shifted;reg signed [15:0] wanted;
 function automatic signed [15:0] sample(input integer index,input integer pattern);
  if(index==0)sample=16'sh8000;
  else if(index==8191)sample=16'sh7fff;
  else sample=((index*7919+pattern*17)%65536)-32768;
 endfunction
 FFT_Processor dut(.calc_clk(clk),.rst(rst),.frame_done_toggle(toggle),
  .time_rd_addr(addr),.time_rd_en(en),.time_rd_data(data),.freq_wr_addr(),.freq_wr_en(),.freq_wr_data(),
  .freq_frame_done_toggle(),.freq_frame_done_pulse(),.frame_valid(),.busy());
 always @(posedge clk)if(en)data<=sample(addr,frame);
 always @(posedge clk)begin
  if(rst)begin n<=0;held<=0;config_held<=0;end
  else begin
   if(held)assert(dut.fft_s_axis_tvalid && dut.fft_s_axis_tdata===held_data && dut.fft_s_axis_tlast===held_last)
    else $fatal(1,"Input payload changed before stalled transfer completed");
   if(config_held)assert(dut.fft_config_tvalid && dut.fft_config_tdata===held_config)
    else $fatal(1,"Config changed before stalled transfer completed");
   held<=dut.fft_s_axis_tvalid && !dut.fft_s_axis_tready;
   config_held<=dut.fft_config_tvalid && !dut.fft_config_tready;
   held_data<=dut.fft_s_axis_tdata;held_last<=dut.fft_s_axis_tlast;held_config<=dut.fft_config_tdata;
   if(dut.fft_s_axis_tvalid && !dut.fft_s_axis_tready)stalls++;
   if(dut.fft_config_tvalid && dut.fft_config_tready)
    assert(dut.fft_config_tdata==1)else $fatal(1,"Not FWD configuration");
   if(dut.fft_s_axis_tvalid && dut.fft_s_axis_tready)begin
    product=$signed(sample(n,frame))*$signed(coefficients[n]);shifted=product>>>15;
    wanted=(shifted>32767)?16'sh7fff:((shifted< -32768)?16'sh8000:shifted[15:0]);
    assert(n<8192 && dut.fft_s_axis_tdata==={16'd0,wanted} && dut.fft_s_axis_tlast===(n==8191))
     else $fatal(1,"Window golden mismatch frame=%0d index=%0d actual=%h expected=%h",frame,n,dut.fft_s_axis_tdata,{16'd0,wanted});
    n<=n+1;total++;
   end
  end
 end
 initial begin
  $readmemb("flat_top_window_rom.mif",coefficients);#200;
  for(frame=0;frame<3;frame++)begin
   rst=1;toggle=0;repeat(8)@(negedge clk);rst=0;repeat(8)@(negedge clk);toggle=1;
   guard=0;while(n<8192 && guard<200000)begin @(negedge clk);guard++;end
   assert(n==8192)else $fatal(1,"Input progress timeout");
  end
  assert(total==24576 && stalls>0)else $fatal(1,"Missing sample/stall coverage");
  $display("PASS: FFT window input-only real-ROM golden checks=%0d forced-stall cycles=%0d",total,stalls);$finish;
 end
 initial begin #10000000;$fatal(1,"Input test timeout");end
endmodule
