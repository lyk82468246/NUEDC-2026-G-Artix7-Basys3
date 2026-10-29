`timescale 1ns/1ps
module tb_display_prepare #(parameter integer W=240,H=160);
    reg clk=0;always #5 clk=~clk;
    reg rst=1;
    task tick;begin @(negedge clk);end endtask
    integer clocks=0;
    always @(posedge clk) clocks<=clocks+1;

    reg dv=0,dr=0;wire di,do_valid,dzero;reg [15:0] dn=0,dd=0;
    wire [15:0] dq,drem;
    Display_Unsigned_Divider #(.WIDTH(16)) div_dut(.clk(clk),.rst(rst),.in_valid(dv),.in_ready(di),
        .numerator(dn),.denominator(dd),.out_valid(do_valid),.out_ready(dr),
        .quotient(dq),.remainder(drem),.divide_by_zero(dzero));
    task division(input integer n,input integer d);integer waiters;begin
        wait(di);tick();dn=n;dd=d;dv=1;tick();dv=0;dn=0;dd=1;
        waiters=0;while(!do_valid && waiters<25) begin tick();waiters++;end
        assert(do_valid) else $fatal(1,"Divider timeout");
        if(d==0) assert(dzero && dq==65535 && drem==n) else $fatal(1,"Zero divide result");
        else assert(!dzero && dq==n/d && drem==n%d) else $fatal(1,"Divide %0d/%0d",n,d);
        repeat(3) begin tick();assert(do_valid && !di) else $fatal(1,"Divider backpressure");end
        dr=1;tick();dr=0;
    end endtask

    reg cv=0,cr=0,csig=1,cbank=1;wire ci,co,c_sig,c_bank,c_voltage,c_over;
    reg [16:0] cpp=100;reg [15:0] crm=20,cam=50;
    reg [1:0] cc=3;reg [35:0] cbins={12'd400,12'd300,12'd100};
    reg [95:0] cmags={32'd30,32'd20,32'd10};
    reg [31:0] cg0=65536,cg1=131072,cg2=196608,cid=1,cep=7;
    wire [31:0] cp,rr,ca,oid,oep;wire [95:0] cps,cfreq;wire [1:0] oc;wire [7:0] ometa;
    Display_Frame_Calibrator cal(.clk(clk),.rst(rst),.in_valid(cv),.in_ready(ci),
        .signal_valid(csig),.calibration_valid(cbank),.vpp_raw(cpp),.rms_raw(crm),.amax_raw(cam),
        .component_count(cc),.component_bins(cbins),.component_magnitudes(cmags),
        .vpp_gain(cg0),.rms_gain(cg1),.fft_gain(cg2),.frame_id(cid),.epoch(cep),.metadata(8'h4f),
        .out_valid(co),.out_ready(cr),.vpp_uv(cp),.rms_uv(rr),.amax_uv(ca),.peaks_uv(cps),
        .frequencies_hz(cfreq),.count_out(oc),.frame_id_out(oid),.epoch_out(oep),.metadata_out(ometa),
        .signal_valid_out(c_sig),.calibration_valid_out(c_bank),.voltage_valid(c_voltage),.overflow(c_over));
    task cal_start;begin wait(ci);tick();cv=1;tick();cv=0;end endtask
    task cal_take;begin cr=1;tick();cr=0;end endtask

    reg fv=0,fok=1;reg [31:0] fuv=0;wire fi,fbv,fbl,fdone;wire [7:0] fbyte;
    wire fready=(clocks%5)>=2;
    Display_mV_Formatter fmt(.clk(clk),.rst(rst),.in_valid(fv),.in_ready(fi),
        .voltage_valid(fok),.microvolts(fuv),.byte_valid(fbv),.byte_ready(fready),
        .byte_data(fbyte),.byte_last(fbl),.done(fdone));
    reg fhold=0;reg [8:0] fheld;
    always @(posedge clk) begin
        if(rst) fhold<=0;
        else begin
            if(fhold) assert(fbv && {fbyte,fbl}==fheld) else $fatal(1,"Formatter backpressure");
            fhold<=fbv && !fready;fheld<={fbyte,fbl};
        end
    end
    task format_value(input reg [31:0] value,input bit valid,input string expected_text);
        integer index,guard;begin
            wait(fi);tick();fuv=value;fok=valid;fv=1;tick();fv=0;fuv=0;fok=0;index=0;guard=0;
            // Inspect handshakes at posedge before the producer's NBA updates.
            while(!fdone && guard<300) begin
                @(posedge clk);
                if(fbv && fready) begin
                    assert(index<expected_text.len() && fbyte==expected_text.getc(index) &&
                           fbl==(index==expected_text.len()-1)) else $fatal(1,"mV formatter byte %0d",index);
                    index++;
                end
                @(negedge clk);guard++;
            end
            assert(fdone && index==expected_text.len()) else $fatal(1,"Formatter timeout/count");tick();
        end
    endtask

    localparam N=8192;
    reg wv=0,wsig=1,wthree=1;reg [11:0] wb=200;reg [31:0] wid=10;
    wire wi,wen,waxis,wgood,wclip,wvalid,wdone,wbusy;
    wire [12:0] wa;reg signed [15:0] wdata=0,mem[0:N-1];
    wire [15:0] wam,wp;wire [7:0] wy;wire [31:0] woid;
    wire wr=(clocks%7)>=3;
    Display_Wave_Renderer #(.W(W),.H(H)) wave(.clk(clk),.rst(rst),.in_valid(wv),.in_ready(wi),
        .signal_valid(wsig),.three_cycles(wthree),.fundamental_bin(wb),.frame_id(wid),
        .rd_en(wen),.rd_addr(wa),.rd_data(wdata),.axis_valid(waxis),.amax_raw(wam),
        .plot_valid(wgood),.window_clamped(wclip),.pixel_valid(wvalid),.pixel_ready(wr),
        .pixel_index(wp),.pixel_y(wy),.frame_id_out(woid),.done(wdone),.busy(wbusy));
    always @(posedge clk) if(wen) begin
        assert(wa<N) else $fatal(1,"BRAM out of range");wdata<=mem[wa];
    end
    integer wn=0,wreads=0,waxes=0,ref_bin=200,ref_cycles=3,ref_amax=32768;
    reg ref_valid=1;
    reg whold=0;reg [55:0] whold_data;
    function integer golden_y(input integer p);
        longint signed pos,a,b,f,first,second,sample_value,abs_value,level;
        begin
            if(!ref_valid || ref_amax==0) golden_y=H/2;
            else begin
                pos=p;pos=pos*ref_cycles*N*4096/((W-1)*ref_bin);
                if(pos>(N-1)*4096) pos=(N-1)*4096;
                a=pos/4096;b=(a==N-1)?a:a+1;f=pos%4096;
                first=mem[a];second=mem[b];
                sample_value=(first*4096+(second-first)*f)>>>12;
                abs_value=(sample_value<0)?-sample_value:sample_value;
                level=(abs_value*((H-1)/2)+ref_amax/2)/ref_amax;
                golden_y=(sample_value<0)?H/2-level:H/2+level;
            end
        end
    endfunction
    always @(posedge clk) begin
        if(rst) whold<=0;
        else begin
            if(whold) assert(wvalid && {wp,wy,woid}==whold_data) else $fatal(1,"Wave held payload changed");
            whold<=wvalid && !wr;whold_data<={wp,wy,woid};
            if(wen) wreads++;
            if(waxis) waxes++;
            if(wvalid && wr) begin
                assert(wp==wn && wy==golden_y(wn) && wy<H && woid==10)
                    else $fatal(1,"Wave pixel %0d: actual %0d expected %0d",wn,wy,golden_y(wn));
                wn++;
            end
        end
    end
    task run_wave(input integer k,input integer c,input bit valid,input bit clipped);
        integer guard;begin
            wait(wi);tick();wn=0;wreads=0;waxes=0;ref_bin=k;ref_cycles=c;ref_valid=valid;
            wb=k;wthree=c==3;wsig=valid;wid=10;wv=1;tick();wv=0;
            // Live input changes after handshake must not affect this frame.
            wb=0;wthree=0;wsig=0;wid=999;
            guard=0;while(!wdone && guard<80000) begin tick();guard++;end
            assert(wdone && wn==W && waxes==1 && wclip==clipped && wgood==(valid && ref_amax!=0))
                else $fatal(1,"Wave completion/count/flags");
            if(valid) assert(wam==ref_amax && wreads==N+((ref_amax==0)?2:2*W)) else $fatal(1,"Amax or BRAM count");
            else assert(wam==0 && wreads==0) else $fatal(1,"Invalid wave touched BRAM");
            tick();
        end
    endtask

    reg sv=0,ssig=1;wire si,sa,sg,scoll,srange,spv,sdone,sbusy;
    reg [1:0] sn=3;reg [95:0] sf={32'd500000,32'd255000,32'd10000};
    reg [95:0] sm={32'd25,32'd50,32'd100};reg [31:0] smin=10000,smax=500000;
    wire [31:0] scale,sid;wire [15:0] sx;wire [7:0] sy;
    wire sr=(clocks%5)>=2;
    Display_Spectrum_Renderer #(.W(W),.H(H)) spectrum(.clk(clk),.rst(rst),.in_valid(sv),.in_ready(si),
        .signal_valid(ssig),.component_count(sn),.frequencies_hz(sf),.magnitudes_raw(sm),
        .frequency_min(smin),.frequency_max(smax),.frame_id(32'd99),
        .axis_valid(sa),.plot_valid(sg),.collision(scoll),.out_of_range(srange),.scale_raw(scale),
        .frame_id_out(sid),.pixel_valid(spv),.pixel_ready(sr),.pixel_index(sx),.pixel_y(sy),
        .done(sdone),.busy(sbusy));
    integer expected[0:W-1],spoints=0,saxes=0;
    reg shold=0;reg [55:0] shold_data;
    always @(posedge clk) begin
        if(rst) shold<=0;
        else begin
            if(shold) assert(spv && {sx,sy,sid}==shold_data) else $fatal(1,"Spectrum held payload changed");
            shold<=spv && !sr;shold_data<={sx,sy,sid};
            if(sa) saxes++;
            if(spv && sr) begin
                assert(sx==spoints && sy==expected[spoints] && sy<H && sid==99)
                    else $fatal(1,"Spectrum pixel %0d: actual %0d expected %0d",spoints,sy,expected[spoints]);
                spoints++;
            end
        end
    end
    task run_spectrum(input bit collide,input bit ranged,input integer good);
        integer guard;begin
            wait(si);tick();spoints=0;saxes=0;sv=1;tick();sv=0;
            sf=0;sm=0;smin=0;smax=0;ssig=0;sn=0;
            guard=0;while(!sdone && guard<2000) begin tick();guard++;end
            assert(sdone && spoints==W && saxes==1 && scoll==collide && srange==ranged && sg==good)
                else $fatal(1,"Spectrum flags/counts");tick();
        end
    endtask
    integer i;
    initial begin
        for(i=0;i<N;i++) mem[i]=(i%32)*100-1500;
        mem[7]=-32768;mem[31]=32767;
        for(i=0;i<W;i++) expected[i]=0;
        repeat(4)tick();rst=0;tick();
        division(65535,17);division(65535,65535);division(1,65535);division(0,1);division(333,0);
        for(i=1;i<30;i++) division((i*1979)%65536,i*37);
        format_value(0,1,"0.0");format_value(49,1,"0.0");format_value(50,1,"0.1");
        format_value(999,1,"1.0");format_value(123456,1,"123.5");
        format_value(32'hffffffff,1,"4294967.3");format_value(123456,0,"--");

        cal_start();cpp=1;crm=2;cam=3;cg0=7;cg1=8;cg2=9;cep=8;cid=2;cmags=0;
        wait(co);tick();
        assert(cp==100 && rr==40 && ca==50 && cps=={32'd90,32'd60,32'd30} &&
            cfreq=={32'd200000,32'd150000,32'd50000} && oid==1 && oep==7 && c_voltage && !c_over)
            else $fatal(1,"Calibration atomic packet/units/order");
        repeat(4)begin tick();assert(co && !ci && cp==100 && oep==7) else $fatal(1,"Cal output hold");end
        cal_take();csig=0;cal_start();wait(co);tick();
        assert(!c_sig && !c_voltage && cp==0 && rr==0 && ca==0 && cps==0 && cfreq==0 && oc==0)
            else $fatal(1,"Invalid packet retained data");cal_take();
        csig=1;cbank=0;cc=1;cal_start();wait(co);tick();
        assert(c_sig && !c_bank && !c_voltage && cp==0 && cps==0 && oc==1 && cfreq==50000)
            else $fatal(1,"Uncalibrated masqueraded as volts");cal_take();
        cbank=1;cg0=32768;cg1=65536;cg2=65536;cpp=1;cc=1;cmags={64'hffffffffffffffff,32'd123};
        cal_start();wait(co);tick();
        assert(cp==1 && cps==96'd123 && c_voltage) else $fatal(1,"Round half-up or unused slots");cal_take();
        cpp=17'h1ffff;crm=16'hffff;cam=16'h8000;cg0=65536;cg1=65536;cg2=65536;
        cmags={64'd0,32'hffffffff};cal_start();wait(co);tick();
        assert(cp==131071 && rr==65535 && ca==32768 && cps[31:0]==32'hffffffff && !c_over)
            else $fatal(1,"Full unsigned calibrated widths");cal_take();
        cg2=32'hffffffff;cmags={64'd0,32'hffffffff};cal_start();wait(co);tick();
        assert(c_over && !c_voltage && cps[31:0]==32'hffffffff) else $fatal(1,"Saturation not flagged");cal_take();

        run_wave(200,3,1,0);run_wave(200,1,1,0);run_wave(1,3,1,1);run_wave(0,1,0,0);
        for(i=0;i<N;i++) mem[i]=0;
        ref_amax=0;run_wave(200,1,1,0);
        expected[0]=H-1;expected[W/2]=H/2;expected[W-1]=(H+1)/4;
        run_spectrum(0,0,1);
        for(i=0;i<W;i++) expected[i]=0;
        sf={32'd500000,32'd10001,32'd10000};sm={32'd50,32'd200,32'd100};smin=10000;smax=500000;ssig=1;sn=3;
        expected[0]=H-1;expected[W-1]=(H+1)/4;run_spectrum(1,0,1);
        for(i=0;i<W;i++) expected[i]=0;
        sf={32'd500000,32'd255000,32'd10000};sm={32'd1,32'h80000000,32'hffffffff};
        smin=10000;smax=500000;ssig=1;sn=3;
        expected[0]=H-1;expected[W/2]=H/2;run_spectrum(0,0,1);
        assert(scale==32'hffffffff) else $fatal(1,"Unsigned spectrum scale truncated");
        for(i=0;i<W;i++) expected[i]=0;
        sf={32'd500001,32'd10000,32'd9999};sm={32'd999,32'd20,32'd999};smin=10000;smax=500000;ssig=1;sn=3;
        expected[0]=H-1;run_spectrum(0,1,1);
        for(i=0;i<W;i++) expected[i]=0;
        sf={32'd500000,32'd255000,32'd10000};sm={32'd25,32'd50,32'd100};smin=10000;smax=10000;ssig=1;sn=3;
        run_spectrum(0,1,0);
        smin=10000;smax=500000;ssig=0;sn=3;run_spectrum(0,0,0);
        // Abort in-flight jobs and verify no stale valid survives reset.
        wait(ci && si && wi && di && fi);cv=1;sv=1;wv=1;dv=1;fv=1;fok=1;wsig=1;wb=200;dd=17;dn=65535;
        tick();cv=0;sv=0;wv=0;dv=0;fv=0;rst=1;tick();
        assert(!co && !spv && !wvalid && !do_valid && !fbv && !ci && !si && !wi && !di && !fi)
            else $fatal(1,"Reset did not cancel work");
        rst=0;tick();assert(ci && si && wi && di && fi && !co && !spv && !wvalid && !do_valid && !fbv)
            else $fatal(1,"Stale result after reset");
        $display("PASS: display preparation %0dx%0d divider/calibration/wave/spectrum/mV, backpressure and invalid/reset",W,H);$finish;
    end
    initial begin #4000000;$fatal(1,"Display preparation timeout");end
endmodule

module tb_display_prepare_compact;
    tb_display_prepare #(.W(200),.H(128)) test();
endmodule

module tb_display_prepare_full_y;
    tb_display_prepare #(.W(17),.H(256)) test();
endmodule
