`timescale 1ns/1ps
// End-to-end new path: actual composite BRAM -> fine period -> actual UART.
module tb_display_aligned_hmi;
    reg clk=0,rst=1,capture=0,tv=0,pv=0,cycles=0;
    always #5 clk=~clk;
    reg signed [15:0] mem[0:8191];
    reg signed [15:0] data;
    wire ren,tx,idle,busy,release_frame,done;
    wire [12:0] addr;
    integer frame=0,pages=0,pauses=0,resumes=0,clears=0,points=0,midpoints=0,rightpoints=0;
    bit paused=0;
    Display_HMI #(.CLK_FREQ_HZ(1152000),.STARTUP_CYCLES(10),
        .COMMAND_GAP_CYCLES(3),.PAGE_GAP_CYCLES(20)) dut(
        .clk(clk),.rst(rst),.capture_start(capture),.allow_redraw(1'b0),
        .time_result_valid(tv),.peak_result_valid(pv),.vpp_raw(17'd7000),.rms_raw(16'd2000),
        .signal_valid(1'b1),.component_count(2'd2),.component_bins({12'd0,12'd346,12'd20}),
        .component_magnitudes({32'd0,32'd2400,32'd1000}),
        .frame_id(32'd1),.calibration_epoch(32'd0),.vpp_gain(32'd65536),
        .rms_gain(32'd65536),.fft_gain(32'd65536),.calibration_valid(1'b1),
        .page_fft_request(1'b0),.three_cycles_request(cycles),.single_mode(1'b0),
        .mode(2'd0),.error_code(4'd0),.time_rd_en(ren),.time_rd_addr(addr),.time_rd_data(data),
        .uart_tx(tx),.tx_idle(idle),.busy(busy),.frame_release(release_frame),
        .measurement_valid(),.signal_valid_out(),.waveform_done(done),.state_debug());
    always @(posedge clk)begin
        if(ren)data<=mem[addr];
        if(busy)assert(!release_frame)else $fatal(1,"Premature frame release");
    end
    initial begin:rx
        reg [7:0] b;reg [511:0] command=0;integer k,ff=0;
        forever begin
            @(negedge tx);
            if(!rst)begin
                #50;assert(!tx)else $fatal(1,"Start bit");
                for(k=0;k<8;k=k+1)begin #100;b[k]=tx;end
                #100;assert(tx)else $fatal(1,"Stop bit");
                if(b==255)begin
                    ff=ff+1;
                    if(ff==3)begin
                        if(command=="page wave")begin
                            pages=pages+1;assert(pages==1)else $fatal(1,"Repeated same-page redraw");
                        end else if(command=="ref_stop")begin
                            assert(!paused)else $fatal(1,"Nested pause");paused=1;pauses=pauses+1;
                        end else if(command=="ref_star")begin
                            paused=0;resumes=resumes+1;
                        end else if(command=="cle 1,0")begin
                            assert(paused)else $fatal(1,"Visible clear outside refresh guard");clears=clears+1;
                        end else if(command[79:24]=="add 1,0" || command[71:16]=="add 1,0" || command[87:32]=="add 1,0")begin
                            assert(paused)else $fatal(1,"Unbuffered plot");points=points+1;
                        end else if(command=="tWaveXMid.txt=\"49.1us\"" || command=="tWaveXMid.txt=\"147.3us\"")begin
                            midpoints=midpoints+1;
                        end else if(command=="tWaveXRight.txt=\"98.2us\"" || command=="tWaveXRight.txt=\"294.6us\"")begin
                            rightpoints=rightpoints+1;
                        end
                        ff=0;command=0;
                    end
                end else begin assert(ff==0)else $fatal(1,"Broken terminator");command=(command<<8)|b;end
            end
        end
    end
    task send_frame(input real phase,input bit three);
        integer i;real p;
        begin
            cycles=three;
            for(i=0;i<8192;i=i+1)begin
                p=6.283185307179586*20.37*i/8192+phase;
                mem[i]=$rtoi(1000*$sin(p)+2400*$sin(17*p+0.7)+200*$sin(3*p-0.4));
            end
            @(negedge clk);capture=1;@(negedge clk);capture=0;tv=1;pv=1;
            @(negedge clk);tv=0;pv=0;
            wait(done);@(negedge clk);
            assert(idle && release_frame && !paused && dut.wave_aligned)else $fatal(1,"Transaction not committed");
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        send_frame(1.7,0);send_frame(4.6,1);
        assert(pages==1 && pauses==2 && resumes==3 && clears==2 && points==480 && midpoints==2 && rightpoints==2)
            else $fatal(1,"Aligned HMI counts page=%d pause=%d resume=%d clear=%d plot=%d mid=%d right=%d",
                pages,pauses,resumes,clears,points,midpoints,rightpoints);
        $display("PASS: full-size aligned composite HMI, actual UART fine-period labels, same-page suppression and refresh transaction");
        $finish;
    end
    initial begin #100000000;$fatal(1,"Aligned HMI timeout");end
endmodule
