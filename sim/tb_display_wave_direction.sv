`timescale 1ns/1ps
// Compare two independent renderer instances under different downstream stalls.
// Model the observed panel placement as physical_x=W-1-stream_ordinal.
module wave_direction_case #(parameter BAND=0,ALIGN=0)(output reg finished=0);
    localparam N=8192,W=240;
    reg clk=0,rst=1,start=0,three=0,signal_ok=1;
    always #5 clk=~clk;
    reg signed [15:0] mem[0:N-1];
    wire [1:0] ready,ren,pv,done,busy,axis,locked,good,clamped;
    wire [12:0] addr[0:1];
    reg signed [15:0] data[0:1];
    wire [15:0] index[0:1],amax[0:1];
    wire [7:0] y[0:1];
    wire [31:0] bin[0:1],id[0:1];
    integer clocks=0,count[0:1],completions[0:1];
    reg [7:0] pixels[0:1][0:W-1];
    always @(posedge clk) clocks<=clocks+1;
    for(genvar g=0;g<2;g=g+1)begin:render
        wire accept=(clocks%(g==0?7:11))>=3;
        reg held=0;
        reg [23:0] held_pixel;
        Display_Wave_Renderer #(.W(W),.BANDLIMITED(BAND),.ENABLE_ALIGNMENT(ALIGN),.REVERSE_X(g)) dut(
            .clk(clk),.rst(rst),.in_valid(start),.in_ready(ready[g]),
            .signal_valid(signal_ok),.three_cycles(three),.fundamental_bin(12'd100),.frame_id(32'd17),
            .rd_en(ren[g]),.rd_addr(addr[g]),.rd_data(data[g]),
            .axis_valid(axis[g]),.amax_raw(amax[g]),.alignment_locked(locked[g]),
            .refined_bin_q20(bin[g]),.plot_valid(good[g]),.window_clamped(clamped[g]),
            .pixel_valid(pv[g]),.pixel_ready(accept),.pixel_index(index[g]),.pixel_y(y[g]),
            .frame_id_out(id[g]),.done(done[g]),.busy(busy[g]));
        always @(posedge clk)begin
            if(ren[g])begin
                assert(addr[g]<N)else $fatal(1,"Read beyond frozen frame");
                data[g]<=mem[addr[g]];
            end
            if(!rst)begin
                if(held)assert(pv[g] && {index[g],y[g]}==held_pixel)
                    else $fatal(1,"Unstable pixel under backpressure");
                if(pv[g] && accept)begin
                    assert(count[g]<W && index[g]==count[g])else $fatal(1,"Ordinal/count");
                    pixels[g][count[g]]=y[g];count[g]=count[g]+1;
                end
                if(done[g])begin
                    assert(count[g]==W && !busy[g])else $fatal(1,"Early completion");
                    completions[g]=completions[g]+1;
                end
            end
            held<=!rst && pv[g] && !accept;
            held_pixel<={index[g],y[g]};
        end
    end
    task frame(input bit span3,input bit valid_signal,input bit expect_lock);
        integer i,different;
        begin
            @(negedge clk);three=span3;signal_ok=valid_signal;
            count[0]=0;count[1]=0;completions[0]=0;completions[1]=0;
            wait(&ready);start=1;@(negedge clk);start=0;
            wait(completions[0]==1 && completions[1]==1);@(negedge clk);
            different=0;
            for(i=0;i<W;i=i+1)begin
                // Reverse stream placed by panel must recover forward time.
                assert(pixels[1][W-1-i]==pixels[0][i])
                    else $fatal(1,"Mirror mismatch BAND=%0d ALIGN=%0d 3T=%0d x=%0d",BAND,ALIGN,span3,i);
                if(pixels[0][i]!=pixels[0][W-1-i])different++;
            end
            assert(amax[0]==amax[1] && locked[0]==locked[1] && bin[0]==bin[1] &&
                good[0]==good[1] && clamped[0]==clamped[1] && id[0]==17 && id[1]==17)
                else $fatal(1,"Direction changed axis/alignment/frame metadata");
            if(valid_signal)begin
                assert(different>W/4)else $fatal(1,"Stimulus insufficiently asymmetric");
                if(ALIGN)assert(locked=={2{expect_lock}})else $fatal(1,"Alignment/fallback path not exercised");
            end
        end
    endtask
    initial begin:stimulus
        integer i;real p;
        count[0]=0;count[1]=0;completions[0]=0;completions[1]=0;
        for(i=0;i<N;i=i+1)begin
            p=6.283185307179586*100*i/N+0.8;
            mem[i]=$rtoi(8000*$sin(p)+2600*$sin(3*p+0.9)+1700*$sin(4*p-0.3));
        end
        repeat(5)@(negedge clk);rst=0;
        frame(0,1,1);frame(1,1,1);
        // No component at the requested fundamental: exercise actual low-
        // confidence fallback with alignment enabled, not only ALIGN=0.
        for(i=0;i<N;i=i+1)begin
            p=6.283185307179586*100*i/N+0.8;
            mem[i]=$rtoi(6000*$sin(3*p+0.9)+3100*$sin(4*p-0.3));
        end
        frame(0,1,0);frame(1,1,0);frame(0,0,0);
        $display("PASS: wave reverse BAND=%0d ALIGN=%0d, 1T/3T/fallback/invalid, stalls and panel placement",BAND,ALIGN);
        finished=1;
    end
endmodule

module tb_display_wave_direction;
    wire [3:0] finished;
    wave_direction_case #(.BAND(0),.ALIGN(0)) a(finished[0]);
    wave_direction_case #(.BAND(1),.ALIGN(0)) b(finished[1]);
    wave_direction_case #(.BAND(0),.ALIGN(1)) c(finished[2]);
    wave_direction_case #(.BAND(1),.ALIGN(1)) d(finished[3]);
    initial begin wait(&finished);$display("PASS: all waveform direction cases");$finish;end
    initial begin #200000000;$fatal(1,"Wave direction timeout");end
endmodule
