`timescale 1ns/1ps
// Decode actual UART wire (including start/stop), not the command FSM's data.
// Goldens cover atomic gain/raw snapshots, selected-page commands, every plot
// point, HOLD replay, no-signal clearing, missing slots, reset and STOP drain.
module tb_display_hmi #(parameter N=64,W=8,YINV=0,PERIODIC=0,GUARD=1);
    localparam H=160,CPB=10;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg capture_start=0,allow_redraw=1,tv=0,pv=0;
    reg [16:0] vpp=2000;reg [15:0] rms=707;
    reg valid=1,calvalid=1,page=0,cycles=0,single_mode=1;
    reg [1:0] count=3,mode=0;
    reg [35:0] test_bins={12'd400,12'd200,12'd20};
    reg [95:0] mags={32'd1000,32'd2000,32'd3000};
    reg [31:0] id=1,epoch=7,gv=65536,gr=65536,gf=65536;
    wire ren,tx,idle,busy,release_frame,measurement,wave_done,sig;
    wire [12:0] addr;reg signed [15:0] rdata;
    reg signed [15:0] memory[0:N-1];
    integer commit_count=0,done_count=0,read_count=0,commands_seen=0,expect_count=0;
    integer packet_end=0;
    integer golden_bin=20;
    reg [511:0] expected[0:8191];
    reg [511:0] received=0;
    integer ff_count=0;
    Display_HMI #(.CLK_FREQ_HZ(1152000),.BAUD_RATE(115200),.FRAME_LENGTH(N),
        .W(W),.H(H),.INVERT_Y(YINV),.WAVE_ALIGNMENT(0),.REFRESH_GUARD(GUARD),.PAGE_REFRESH_FRAMES(PERIODIC),.ENABLE_STATUS(1),.STARTUP_CYCLES(1000),
        .COMMAND_GAP_CYCLES(3),.PAGE_GAP_CYCLES(20)) dut(
        .clk(clk),.rst(rst),.capture_start(capture_start),.allow_redraw(allow_redraw),
        .time_result_valid(tv),.peak_result_valid(pv),.vpp_raw(vpp),.rms_raw(rms),
        .signal_valid(valid),.component_count(count),.component_bins(test_bins),.component_magnitudes(mags),
        .frame_id(id),.calibration_epoch(epoch),.vpp_gain(gv),.rms_gain(gr),.fft_gain(gf),
        .calibration_valid(calvalid),.page_fft_request(page),.three_cycles_request(cycles),
        .single_mode(single_mode),.mode(mode),.error_code(4'd0),
        .time_rd_en(ren),.time_rd_addr(addr),.time_rd_data(rdata),
        .uart_tx(tx),.tx_idle(idle),.busy(busy),.frame_release(release_frame),
        .measurement_valid(measurement),.signal_valid_out(sig),.waveform_done(wave_done),.state_debug());
    always @(posedge clk) begin
        if(ren) begin
            assert(addr<N) else $fatal(1,"BRAM address overflow");
            rdata<=memory[addr];read_count<=read_count+1;
        end
        if(measurement) commit_count<=commit_count+1;
        if(wave_done) begin
            assert(idle && tx && release_frame && !busy) else $fatal(1,"Released before UART STOP/gap drain");
            done_count<=done_count+1;
        end
        if(busy) assert(!release_frame) else $fatal(1,"Frame release during read/serialization");
    end
    // Independent 8N1 receiver. Command checks include names, units and FFs.
    initial begin:receiver
        reg [7:0] byte_value;integer k;
        forever begin
            @(negedge tx);
            if(!rst) begin
                #(CPB*10/2);assert(!tx) else $fatal(1,"Bad UART start");
                for(k=0;k<8;k=k+1) begin #(CPB*10);byte_value[k]=tx;end
                #(CPB*10);assert(tx) else $fatal(1,"Bad UART stop");
                if(byte_value==255) begin
                    ff_count=ff_count+1;
                    if(ff_count==3) begin
                        assert(commands_seen<expect_count) else $fatal(1,"Unexpected command: %s",received);
                        assert(received==expected[commands_seen]) else
                            $fatal(1,"Command %0d got [%s] expected [%s]",commands_seen,received,expected[commands_seen]);
                        commands_seen=commands_seen+1;received=0;ff_count=0;
                    end
                end else begin
                    assert(ff_count==0 && byte_value!=10 && byte_value!=13) else $fatal(1,"Bad terminator/newline");
                    received=(received<<8)|byte_value;
                end
            end
        end
    end
    task add(input [511:0] s);begin expected[expect_count]=s;expect_count=expect_count+1;end endtask
    task text(input [127:0] name,input [159:0] value);
        reg [511:0] result;integer k;
        begin
            result=name;
            result={result[463:0],".txt=\""};
            for(k=19;k>=0;k=k-1)if(value[k*8+:8]!=0)result=(result<<8)|value[k*8+:8];
            add((result<<8)|8'h22);
        end
    endtask
    task plot(input integer y);
        reg [511:0] result;
        begin $sformat(result,"add 1,0,%0d",y);add(result);end
    endtask
    // Fixed-point coordinate golden, signed 64-bit, independently divided.
    task wave_points(input integer c,input bit source_ok);
        longint signed coord,a,b,frac,s,y,absolute;integer p,batch_first;
        begin
            for(p=0;p<W;p=p+1) begin
                coord=(64'(p)*c*N*4096)/((W-1)*golden_bin);a=coord/4096;frac=coord%4096;
                b=(a==N-1)?a:a+1;
                s=(64'(memory[a])*4096+(64'(memory[b])-memory[a])*frac)>>>12;
                absolute=(s<0)?-s:s;y=(absolute*79+500)/1000;
                y=(s<0)?80-y:80+y;
                if(!source_ok)y=80;
                plot(YINV?H-1-y:y);
            end
        end
    endtask
    task time_text(input [127:0] name,input integer c,input bit mid,input bit source_ok);
        longint numerator,denominator,ticks;
        reg [159:0] value;
        begin
            numerator=64'd10000000*c;denominator=64'(golden_bin)*500*(mid?2:1);
            ticks=(numerator+denominator/2)/denominator;
            $sformat(value,"%0d.%0dus",ticks/10,ticks%10);
            text(name,source_ok?value:"--");
        end
    endtask
    // Independent command transaction golden: buffered curve, then labels,
    // explicit curve refresh and resume; the UART STOP/gap still gates release.
    task guarded_order(input integer first,input integer fields);
        reg [511:0] saved[0:300];integer k,last;
        begin
            last=expect_count-first;
            for(k=0;k<last;k=k+1)saved[k]=expected[first+k];
            expect_count=first;
            if(GUARD)add("ref_stop");
            for(k=fields;k<last;k=k+1)add(saved[k]);
            for(k=0;k<fields;k=k+1)add(saved[k]);
            if(GUARD)begin add("ref 1");add("ref_star");end
        end
    endtask
    task wave_packet(input bit send_page,input integer c,input integer status_kind);
        // status_kind: 0 valid calibrated, 1 no signal, 2 uncalibrated.
        reg [159:0] expected_frequency;integer batch_first;
        begin
            if(send_page)add("page wave");batch_first=expect_count;
            text("tUpp",status_kind==0?"2.0mV":"--");
            text("tUrms",status_kind==0?"0.7mV":"--");
            $sformat(expected_frequency,"%0dHz",golden_bin*500);
            text("tF1",status_kind==1?"--":expected_frequency);
            text("tWaveYTop",status_kind==0?"+1.0mV":"--");text("tWaveY0","0");
            text("tWaveYBot",status_kind==0?"-1.0mV":"--");
            text("tWaveSpan",c==3?"3T":"1T");text("tWaveXLeft","0us");
            time_text("tWaveXMid",c,1,status_kind!=1);
            time_text("tWaveXRight",c,0,status_kind!=1);
            text("tStatus",status_kind==1?"NO SIGNAL":(status_kind==2?"CAL":"HOLD"));
            add("cle 1,0");wave_points(c,status_kind!=1);guarded_order(batch_first,11);
        end
    endtask
    task fft_packet(input bit send_page,input integer components,input bit calibrated,input integer maxfreq);
        integer p,y,batch_first;
        begin
            if(send_page)add("page fft");batch_first=expect_count;
            text("tF1","10000Hz");text("tA1",calibrated?"3.0mV":"--");
            text("tF2",components>1?"100000Hz":"--");text("tA2",calibrated && components>1?"2.0mV":"--");
            text("tF3",components>2?"200000Hz":"--");text("tA3",calibrated && components>2?"1.0mV":"--");
            text("tFftYTop",calibrated?"3.0mV":"--");text("tFftYMid",calibrated?"1.5mV":"--");text("tFftY0","0");
            text("tFftXLeft","0kHz");text("tFftXMid",maxfreq==200000?"100kHz":"250kHz");
            text("tFftXRight",maxfreq==200000?"200kHz":"500kHz");
            text("tStatus",calibrated?"HOLD":"CAL");add("cle 1,0");
            for(p=0;p<W;p=p+1) begin
                y=0;if(p==(10000*(W-1)+maxfreq/2)/maxfreq)y=159;
                if(components>1 && p==(100000*(W-1)+maxfreq/2)/maxfreq && y<106) y=106;
                if(components>2 && p==(200000*(W-1)+maxfreq/2)/maxfreq && y<53) y=53;
                plot(YINV?H-1-y:y);
            end
            guarded_order(batch_first,13);
        end
    endtask
    task new_frame;
        begin
            @(negedge clk);capture_start=1;@(negedge clk);capture_start=0;
            tv=1;@(negedge clk);tv=0;repeat(7)@(negedge clk);pv=1;@(negedge clk);pv=0;
        end
    endtask
    task fft_invalid(input bit send_page);
        integer p,batch_first;
        begin
            if(send_page)add("page fft");batch_first=expect_count;
            text("tF1","--");text("tA1","--");text("tF2","--");text("tA2","--");
            text("tF3","--");text("tA3","--");text("tFftYTop","--");text("tFftYMid","--");text("tFftY0","0");
            text("tFftXLeft","0kHz");text("tFftXMid","250kHz");text("tFftXRight","500kHz");text("tStatus","NO SIGNAL");
            add("cle 1,0");for(p=0;p<W;p=p+1)plot(YINV?159:0);guarded_order(batch_first,13);
        end
    endtask
    task fft_half_rounding_edge;
        integer p,batch_first;
        begin
            add("page fft");batch_first=expect_count;text("tF1","10000Hz");text("tA1","0.1mV");
            text("tF2","--");text("tA2","--");text("tF3","--");text("tA3","--");
            text("tFftYTop","0.1mV");text("tFftYMid","0.0mV");text("tFftY0","0");
            text("tFftXLeft","0kHz");text("tFftXMid","100kHz");text("tFftXRight","200kHz");
            text("tStatus","HOLD");add("cle 1,0");
            for(p=0;p<W;p=p+1)plot(YINV?159-((p==(10000*(W-1)+100000)/200000)?159:0):
                ((p==(10000*(W-1)+100000)/200000)?159:0));
            guarded_order(batch_first,13);
        end
    endtask
    task finish_packet(input integer target_done);
        begin
            wait(done_count==target_done);@(negedge clk);
            assert(commands_seen==expect_count && !busy && release_frame && idle) else $fatal(1,"Incomplete packet");
            repeat(50)@(negedge clk);
        end
    endtask
    integer i,j;
    initial begin
        for(i=0;i<N;i=i+1) begin
            case(i%16)
                0:memory[i]=0;1:memory[i]=250;2:memory[i]=500;3:memory[i]=750;4:memory[i]=1000;
                5:memory[i]=750;6:memory[i]=500;7:memory[i]=250;8:memory[i]=0;9:memory[i]=-250;
                10:memory[i]=-500;11:memory[i]=-750;12:memory[i]=-1000;13:memory[i]=-750;
                14:memory[i]=-500;15:memory[i]=-250;
            endcase
        end
        repeat(5)@(negedge clk);rst=0;
        add(512'd0);if(GUARD)add("ref_star");wave_packet(1,1,0);new_frame();wait(measurement);@(negedge clk);
        // Change live gains/raw AFTER the shared measurement edge; active frame
        // and all HOLD redraws must retain old epoch 7/gain 1.0.
        @(negedge clk);gv=131072;gr=131072;gf=131072;epoch=8;vpp=999;rms=999;mags=0;
        // Mid-command UI changes cannot mutate the active page/span. The most
        // recent request wins at the next safe boundary (here changed back).
        page=1;cycles=1;wait(commands_seen>=5);@(negedge clk);page=0;cycles=0;
        finish_packet(1);
        assert(dut.epoch==7 && commit_count==1)else $fatal(1,"Mixed calibration epoch");
        allow_redraw=0;page=1;repeat(100)@(negedge clk);
        assert(!busy && done_count==1)else $fatal(1,"Replay ignored capture ownership");
        fft_packet(1,3,1,200000);allow_redraw=1;finish_packet(2);
        assert(commit_count==1)else $fatal(1,"HOLD replay fabricated measurement");
        wave_packet(1,3,0);page=0;cycles=1;finish_packet(3);
        assert(commit_count==1 && dut.raw_vpp==2000)else $fatal(1,"HOLD raw changed");
        // Default spec repeats only the selected page, never alternates pages.
        valid=0;id=2;wave_packet(PERIODIC==1,3,1);new_frame();finish_packet(4);
        assert(!sig && commit_count==2)else $fatal(1,"No-signal event missing");
        // Uncalibrated valid signal retains frequency/shape, never fake mV.
        valid=1;calvalid=0;count=1;mags={64'd0,32'd3000};vpp=2000;rms=707;id=3;
        wave_packet(PERIODIC==1 || PERIODIC==2,3,2);new_frame();finish_packet(5);
        fft_packet(1,1,0,200000);page=1;finish_packet(6);
        // Mode B range, only requested page is refreshed (no automatic flip).
        mode=1;id=4;fft_packet(PERIODIC==1,1,0,500000);new_frame();finish_packet(7);
        valid=0;id=5;fft_invalid(PERIODIC==1 || PERIODIC==2);new_frame();finish_packet(8);
        // capture_start cancels stale HOLD replay before any BRAM read.
        @(negedge clk);capture_start=1;page=0;@(negedge clk);capture_start=0;
        repeat(100)@(negedge clk);assert(!busy && !dut.have_frame)else $fatal(1,"Stale frame replay");
        // Exact spec example (100kHz), fractional periods (10.5kHz), upper
        // production band (500kHz), and sub-us/half-up formatting (2MHz debug).
        for(j=0;j<4;j=j+1) begin
            allow_redraw=0;cycles=0;page=0;valid=1;mode=3;
            golden_bin=(j==0)?200:((j==1)?21:((j==2)?1000:4000));
            test_bins=golden_bin;id=6+j;
            wave_packet(j==0 || PERIODIC>0,1,2);new_frame();wait(measurement);@(negedge clk);allow_redraw=1;
            finish_packet(9+j*2);
            wave_packet(PERIODIC==1,3,2);cycles=1;finish_packet(10+j*2);
        end
        // 99uV full scale has a 49.5uV midpoint: avoid double rounding to .1mV.
        allow_redraw=0;page=1;mode=0;calvalid=1;gv=65536;gr=65536;gf=65536;
        golden_bin=20;test_bins=20;mags=99;id=10;
        fft_half_rounding_edge();new_frame();wait(measurement);@(negedge clk);allow_redraw=1;
        finish_packet(17);
        // Reset during an in-flight UART packet: state/valids/release cancel.
        valid=1;page=0;allow_redraw=0;calvalid=0;
        wave_packet(1,3,2);tv=1;@(negedge clk);tv=0;pv=1;@(negedge clk);pv=0;
        wait(busy && !tx);@(negedge clk);rst=1;repeat(3)@(negedge clk);
        assert(tx && !busy && !release_frame && !measurement)else $fatal(1,"Reset cancellation");
        $display("PASS: UART spec including us/FFT midpoint labels, zero-origin plot, page policy, atomic gains, all pixels, HOLD, invalid/CAL, reset/STOP drain");
        $finish;
    end
    initial begin #100_000_000;$fatal(1,"Display HMI timeout state=%0d cmds=%0d/%0d",dut.state,commands_seen,expect_count);end
endmodule
module tb_display_hmi_full;
    tb_display_hmi #(.N(8192),.W(240)) t();
endmodule
module tb_display_hmi_inverted;
    tb_display_hmi #(.YINV(1),.PERIODIC(2)) t();
endmodule

module tb_display_hmi_no_guard;
    tb_display_hmi #(.GUARD(0)) t();
endmodule
