`timescale 1ns/1ps
module tb_measurement_calibrator;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0,cal=0;
    reg [31:0] tg=524288,fg=16384;
    reg [16:0] pp=3200;reg [15:0] rms=867;
    reg [95:0] components={32'd3072,32'd2048,32'd1024};
    wire [31:0] pp_mv,rms_mv;wire [95:0] peak_mv;
    wire valid,overflow,busy,done;
    Measurement_Calibrator dut(.clk(clk),.rst(rst),.start(start),.calibration_valid(cal),
        .gain_time_q24(tg),.gain_fft_q24(fg),.vpp_raw(pp),.rms_raw(rms),.component_raw(components),
        .vpp_mv(pp_mv),.rms_mv(rms_mv),.component_peak_mv(peak_mv),
        .valid(valid),.overflow(overflow),.busy(busy),.done(done));
    task tick;begin @(negedge clk);end endtask
    initial begin
        repeat(5) tick();rst=0;start=1;tick();start=0;
        assert(done && !valid && pp_mv==0) else $fatal(1,"Uncalibrated result mislabeled");
        tick();cal=1;start=1;tick();start=0;tg=0;fg=0;components=0;
        wait(done);tick();
        assert(valid && !overflow && pp_mv==100 && rms_mv==27 && peak_mv=={32'd3,32'd2,32'd1})
            else $fatal(1,"Q24 or snapshot mismatch");
        fg=32'hffffffff;components={3{32'hffffffff}};start=1;tick();start=0;
        wait(done);tick();assert(overflow && peak_mv=={3{32'hffffffff}}) else $fatal(1,"No saturation");
        cal=0;start=1;tick();start=0;
        assert(!valid && pp_mv==0 && peak_mv==0) else $fatal(1,"Old calibration leaked");
        $display("PASS: tb_measurement_calibrator Q24 units, rounding, atomic gains, saturation and invalid calibration");
        $finish;
    end
    initial begin #10000;$fatal(1,"Calibrator watchdog");end
endmodule
