`timescale 1ns/1ps
// Protocol/ownership regression; legacy tb_hmi_uart separately decodes 8N1.
module tb_hmi_signal_valid;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,tv=0,pv=0,sv=1;
    reg [15:0] rms=200;
    wire done,busy,release_frame,packet_valid,signal_valid,tx_idle,rd_en;
    wire [5:0] addr;
    reg signed [15:0] data=0;
    reg [7:0] bytes[0:1023];
    integer n=0,reads=0,cycles,i,j;
    string expected;
    HMI_UART_Ctrl #(.CLK_FREQ_HZ(1152000),.BAUD_RATE(115200),
        .FRAME_LENGTH(64),.TIME_ADDR_WIDTH(6),.WAVE_POINTS(4),
        .VALIDATE_SIGNAL(1),.MIN_SIGNAL_RMS(64)) dut(
        .clk(clk),.rst(rst),.time_result_valid(tv),.vpp_in(17'd1000),.vrms_in(rms),
        .peak_result_valid(pv),.f1_index_in(12'd8),.f1_hz_in(32'd4000),.amp_f1_in(32'd10000),
        .signal_valid_in(sv),.signal_valid_out(signal_valid),.display_three_cycles(1'b0),
        .time_rd_en(rd_en),.time_rd_addr(addr),.time_rd_data(data),.uart_tx(),.tx_idle(tx_idle),
        .busy(busy),.waveform_done(done),.frame_release(release_frame),
        .measurement_valid(packet_valid),.state_debug());
    always @(posedge clk) if(!rst) begin
        if(dut.uart_start) begin bytes[n]=dut.uart_data;n=n+1;end
        if(rd_en) begin reads=reads+1;data<=($signed({1'b0,addr})-32)*10;end
    end
    task tick;begin @(negedge clk);end endtask
    task publish;
        input integer rms_value;
        input spectral_ok,peak_first;
        begin
            n=0;reads=0;rms=rms_value;sv=spectral_ok;
            if(peak_first) begin pv=1;tick();pv=0;sv=~spectral_ok;repeat(3)tick();tv=1;tick();tv=0;end
            else begin tv=1;tick();tv=0;repeat(3)tick();pv=1;tick();pv=0;sv=~spectral_ok;end
            cycles=0;
            while(!packet_valid && cycles<100)begin tick();cycles=cycles+1;end
            assert(packet_valid) else $fatal(1,"No completed-result event");
            assert(signal_valid==(spectral_ok && rms_value>=64)) else $fatal(1,"Validity used wrong pending frame");
            assert(!release_frame) else $fatal(1,"Previous release was not withdrawn");
            cycles=0;
            while(!(release_frame && tx_idle && !busy) && cycles<100000)begin tick();cycles=cycles+1;end
            assert(cycles<100000)else $fatal(1,"Invalid frame deadlocked AFE ownership");
            repeat(3)tick();
        end
    endtask
    task check_invalid;
        begin
            assert(n==66 && reads==0) else $fatal(1,"Invalid packet drew noise or omitted clear: bytes=%0d reads=%0d",n,reads);
            for(i=0;i<4;i=i+1)begin
                expected=$sformatf("t%0d.txt=\"--\"",i);
                for(j=0;j<11;j=j+1)assert(bytes[i*14+j]==expected[j])else $fatal(1,"Invalid text byte");
                for(j=11;j<14;j=j+1)assert(bytes[i*14+j]==8'hff)else $fatal(1,"Text terminator");
            end
            expected="cle 1,0";
            for(j=0;j<7;j=j+1)assert(bytes[56+j]==expected[j])else $fatal(1,"Old curve not cleared");
            for(j=63;j<66;j=j+1)assert(bytes[j]==8'hff)else $fatal(1,"Clear terminator");
        end
    endtask
    initial begin
        repeat(5)tick();rst=0;repeat(5)tick();
        publish(200,1,0);assert(reads>0)else $fatal(1,"Valid packet did not draw");
        publish(20,1,1);check_invalid(); // coherent low-level spur, not valid input
        publish(200,0,0);check_invalid(); // broadband/inconsistent spectrum
        publish(312,1,1);assert(reads>0 && signal_valid)else $fatal(1,"No recovery after invalid packets");
        $display("PASS: tb_hmi_signal_valid atomic time/peak ordering, -- text, clear-only invalid, stop-bit release and recovery");$finish;
    end
    initial begin #5000000;$fatal(1,"HMI validity watchdog");end
endmodule
