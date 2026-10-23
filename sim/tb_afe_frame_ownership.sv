`timescale 1ns/1ps
// Uses the isolated FIR stub in tb_afe_small_signal.sv; no real FIR model.
module tb_afe_frame_ownership;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,enable=0,release_frame=1;
    reg [11:0] data=2048;
    reg valid=0;
    wire wr,done,start;
    wire [3:0] addr;
    wire signed [15:0] sample;
    integer n=0,frames=0,writes=0;
    AFE_Capture #(.FRAME_LENGTH(16),.ADDR_WIDTH(4),.DC_WARMUP_SAMPLES(0),.CONTROLLED_CAPTURE(1)) dut(
        .adc_clk(clk),.rst(rst),.adc_data(data),.sample_valid(valid),
        .capture_enable(enable),.frame_release(release_frame),.bram_wr_en(wr),
        .bram_wr_addr(addr),.bram_wr_data(sample),.frame_start_pulse(start),
        .frame_done_pulse(done),.frame_done_toggle(),.capture_busy());
    always @(negedge clk) if(!rst) begin
        n=n+1; valid=(n%3==0);
        data=(n%12<6)?2073:2023;
    end
    always @(posedge clk) if(!rst) begin
        if(done) frames=frames+1;
        if(wr) writes=writes+1;
    end
    task tick; begin @(negedge clk); end endtask
    initial begin
        repeat(5) tick();rst=0;
        repeat(200) tick();assert(frames==0 && writes==0) else $fatal(1,"Captured without permit");
        enable=1;wait(start);tick();enable=0;
        wait(done);repeat(80) tick();
        assert(frames==1 && writes==16) else $fatal(1,"Stale release overwrote owned frame");
        release_frame=0;repeat(4) tick();release_frame=1;
        repeat(80) tick();assert(frames==1) else $fatal(1,"Release bypassed single-shot permit");
        enable=1;wait(start);tick();enable=0;
        wait(done);repeat(80) tick();
        assert(frames==2 && writes==32) else $fatal(1,"New frame stale handshake");
        $display("PASS: tb_afe_frame_ownership no-permit, exact16 writes, stale release and rearm");
        $finish;
    end
    initial begin #200000; $fatal(1,"AFE ownership watchdog"); end
endmodule
