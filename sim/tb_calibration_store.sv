`timescale 1ns/1ps
// NOR x1 wire model: actual command bytes, WREN/WIP, 4KiB erase, page bounds,
// 1->0 programming. Persistent array survives FPGA POR and front-panel reset.
module tb_calibration_store;
    localparam [96:0] A={1'b1,32'd3623460,32'd3701829,32'd4194};
    localparam [96:0] B={1'b1,32'd3600000,32'd3750000,32'd4200};
    localparam [96:0] C={1'b1,32'd3500000,32'd3800000,32'd4300};
    localparam [96:0] D={1'b1,32'd3400000,32'd3900000,32'd4400};
    reg clk=0,por=1,panel=0,req=0,vreq=1;
    always #5 clk=~clk;
    reg [1:0] command=0;
    reg [96:0] staging=0;
    wire [96:0] active,restore_bank,saved_bank;
    wire [31:0] epoch,status,seq,saved_epoch;
    wire restore,restore_ready,cal_ready,blocked,vack,rejected,runtime_busy;
    wire cs,sck,mosi,miso;
    Runtime_Calibration #(.EXTERNAL_BANK(1),.DEFAULT_ENABLED(1),
        .DEFAULT_VPP_GAIN(3623460),.DEFAULT_RMS_GAIN(3701829),.DEFAULT_FFT_GAIN(4194)) runtime(
        .clk(clk),.rst(por|panel),.request_toggle(vreq),.staging_valid(staging[96]),
        .staging_vpp_gain(staging[95:64]),.staging_rms_gain(staging[63:32]),.staging_fft_gain(staging[31:0]),
        .sample_valid(1'b0),.signal_valid(1'b0),.vpp_raw(17'd0),.rms_raw(16'd0),.fft_raw(32'd0),
        .ack_toggle(vack),.epoch(epoch),.result_epoch(),.result_count(),
        .active_vpp_gain(active[95:64]),.active_rms_gain(active[63:32]),.active_fft_gain(active[31:0]),
        .active_valid(active[96]),.vpp_uv(),.rms_uv(),.peak_uv(),.valid(),.overflow(),
        .busy(runtime_busy),.done(),.overrun(),.restore_valid(restore),.restore_bank(restore_bank),
        .restore_ready(restore_ready),.request_block(blocked),.packet_busy(1'b0),.commit_rejected(rejected));
    Calibration_Store #(.HALF_PERIOD(2),.POLL_GAP(2),.MAX_POLLS(16)) dut(
        .clk(clk),.por(por),.panel_reset(panel),.request_toggle(req),.command(command),
        .active_bank(active),.active_epoch(epoch),.apply_pending(vreq!=vack),.runtime_busy(runtime_busy),
        .restore_valid(restore),.restore_ready(restore_ready),.restore_bank(restore_bank),
        .calibration_ready(cal_ready),.apply_block(blocked),.status(status),.jedec_id(),
        .saved_sequence(seq),.saved_epoch(saved_epoch),.saved_bank(saved_bank),
        .cs_n(cs),.sck(sck),.mosi(mosi),.miso(miso));
    reg [7:0] memory[0:8191],program_buffer[0:255];
    reg [7:0] incoming=0,opcode=0,response=8'hff;
    reg [23:0] address=0;
    integer bit_count=0,byte_count=0,program_count=0,nor_wip=0,erase_count=0,program_commands=0;
    reg wel=0,corrupt_body_read=0;
    reg [7:0] protection=0,security_fault=0;
    integer j;
    function integer offset(input [23:0] a);
        begin
            if(a>=24'h3e0000 && a<24'h3e1000)offset=a-24'h3e0000;
            else if(a>=24'h3f0000 && a<24'h3f1000)offset=4096+a-24'h3f0000;
            else offset=-1;
        end
    endfunction
    function [7:0] at_address(input [23:0] a);
        integer p;
        begin
            p=offset(a);at_address=p<0?8'hff:memory[p];
            if(corrupt_body_read && dut.state==38 && a[11:0]==0)at_address=at_address^1;
        end
    endfunction
    assign miso=cs?1'b1:response[7-bit_count];
    always @(negedge cs)begin bit_count=0;byte_count=0;program_count=0;incoming=0;address=0;response=8'hff;end
    always @(posedge sck)if(!cs)begin
        if(opcode==8'h03 && byte_count>=4 && bit_count==0)
            assert(offset(address)>=0)else $fatal(1,"Read outside reserved extents");
        incoming={incoming[6:0],mosi};
        if(bit_count==7)begin
            if(byte_count==0)begin
                opcode=incoming;
                assert(opcode inside {8'h9f,8'h05,8'h03,8'h06,8'h02,8'h20,8'h2b})
                    else $fatal(1,"Forbidden opcode %h",opcode);
                if(nor_wip>0)assert(opcode==8'h05)else $fatal(1,"Access while WIP");
            end else if(opcode==8'h03 || opcode==8'h02 || opcode==8'h20)begin
                if(byte_count<=3)address={address[15:0],incoming};
                else if(opcode==8'h03)address=address+1;
                else if(opcode==8'h02)begin
                    assert(program_count<256)else $fatal(1,"PP overrun");program_buffer[program_count]=incoming;program_count=program_count+1;
                end
            end
            byte_count=byte_count+1;bit_count=0;incoming=0;
            case(opcode)
                8'h9f:case(byte_count)1:response=8'hc2;2:response=8'h20;3:response=8'h16;default:response=8'hff;endcase
                8'h05:begin response=8'h40 | protection | (wel?2:0) | (nor_wip>0?1:0);if(byte_count==1 && nor_wip>0)nor_wip=nor_wip-1;end
                8'h03:response=byte_count>=4?at_address(address):8'hff;
                8'h2b:response=security_fault;
                default:response=8'hff;
            endcase
        end else bit_count=bit_count+1;
    end
    always @(posedge cs)if(byte_count!=0)begin
        case(opcode)
            8'h06:begin assert(nor_wip==0)else $fatal(1,"WREN while WIP");wel=1;end
            8'h20:if(byte_count==4)begin
                assert(wel && address[11:0]==0 && offset(address)>=0)else $fatal(1,"Unsafe erase");
                for(j=0;j<4096;j=j+1)memory[offset(address)+j]=8'hff;
                wel=0;nor_wip=2;erase_count=erase_count+1;
            end
            8'h02:if(program_count!=0)begin
                assert(wel && address[7:0]+program_count<=256 && offset(address)>=0)
                    else $fatal(1,"WEL/page/range violation");
                for(j=0;j<program_count;j=j+1)begin
                    assert((memory[offset(address)+j]&program_buffer[j])==program_buffer[j])else $fatal(1,"NOR 0->1");
                    memory[offset(address)+j]=memory[offset(address)+j]&program_buffer[j];
                end
                wel=0;nor_wip=2;program_commands=program_commands+1;
            end
        endcase
    end
    task wait_idle;begin wait(cal_ready && !status[0]);@(negedge clk);end endtask
    task apply(input [96:0] value);
        begin wait_idle();@(negedge clk);staging=value;vreq=~vreq;wait(vack==vreq);@(negedge clk);
            assert(active==value && !rejected)else $fatal(1,"Volatile apply");end
    endtask
    task start_command(input [1:0] op);
        begin wait_idle();@(negedge clk);command=op;req=~req;end
    endtask
    task command_done;
        begin wait(status[9]==req && !status[0]);@(negedge clk);end
    endtask
    task fpga_power_cycle;
        begin @(negedge clk);por=1;repeat(5)@(negedge clk);por=0;wait_idle();end
    endtask
    integer i,before_erases;
    reg [7:0] golden[0:159];
    initial begin
        for(i=0;i<8192;i=i+1)memory[i]=8'hff;
        repeat(5)@(negedge clk);por=0;wait_idle();
        assert(active==A && vack==1 && status[8:5]==3 && epoch==1)else $fatal(1,"Blank boot/default/rebase");
        apply(B);start_command(1);command_done();
        assert(status[8:5]==0 && status[4:3]==1 && seq==0 && saved_bank==B && saved_epoch==2)else $fatal(1,"First save");
        before_erases=erase_count;start_command(1);command_done();
        assert(erase_count==before_erases && seq==0)else $fatal(1,"Identical bank caused wear");
        apply(C);@(negedge clk);panel=1;repeat(6)@(negedge clk);panel=0;wait_idle();
        assert(active==B && vack==vreq && epoch==1)else $fatal(1,"Panel restore / stale VIO replay");
        apply(C);start_command(1);command_done();
        assert(saved_bank==C && seq==1 && status[4:3]==2)else $fatal(1,"Second slot");
        apply(D);start_command(1);
        wait(dut.state==24 && dut.write_phase==2); // body verified, no commit written yet
        fpga_power_cycle();assert(active==C && saved_bank==C && seq==1)else $fatal(1,"Precommit power cut");
        apply(D);start_command(1);wait(dut.state==40); // commit is on flash, ack not yet returned
        fpga_power_cycle();assert(active==D && saved_bank==D && seq==2)else $fatal(1,"Committed power cut");
        apply(B);start_command(1);wait(dut.state==24 && dut.write_phase==1);
        @(negedge clk);panel=1;repeat(6)@(negedge clk);panel=0;wait_idle();
        assert(active==B && saved_bank==B && seq==3)else $fatal(1,"BtnC interrupted save instead of deferring restore");
        apply(C);start_command(1);wait(dut.state==24 && dut.write_phase==1);
        @(negedge clk);staging=D;vreq=~vreq;wait(vack==vreq);@(negedge clk);
        assert(rejected && active==C)else $fatal(1,"Apply accepted during save");command_done();
        assert(saved_bank==C && active==C)else $fatal(1,"Snapshot mixed");
        apply(D);corrupt_body_read=1;start_command(1);command_done();
        assert(status[8:5]==11)else $fatal(1,"Body readback error ignored");corrupt_body_read=0;
        fpga_power_cycle();assert(active==C)else $fatal(1,"Readback failure committed new record");
        before_erases=erase_count;
        if(status[4:3]==1)memory[4096+512]=0;else memory[512]=0;
        apply(D);start_command(1);command_done();
        assert(status[8:5]==9 && erase_count==before_erases)else $fatal(1,"Foreign target contents erased");
        // New fixture: only sequence FFFFFFFF exists, so next save must wrap.
        $readmemh("flash_valid.mem",golden);
        for(i=0;i<8192;i=i+1)memory[i]=8'hff;
        for(i=0;i<64;i=i+1)memory[i]=golden[i];
        for(i=0;i<16;i=i+1)memory[256+i]=golden[64+i];
        fpga_power_cycle();assert(seq==32'hffffffff && active==A)else $fatal(1,"Wrap fixture restore");
        apply(B);start_command(1);command_done();
        assert(seq==0 && saved_bank==B && status[4:3]==2)else $fatal(1,"Save sequence wrap");
        fpga_power_cycle();assert(seq==0 && active==B)else $fatal(1,"Wrapped sequence selection");
        apply(C);before_erases=erase_count;protection=4;start_command(1);command_done();
        assert(status[8:5]==6 && erase_count==before_erases)else $fatal(1,"Protected flash was modified");
        protection=0;security_fault=8'h20;start_command(1);command_done();
        assert(status[8:5]==13 && erase_count==before_erases)else $fatal(1,"Security failure ignored");
        $display("PASS: actual SPI NOR save/restore, WREN/WIP/page/partition, A/B commit power cuts, BtnC, atomic bank, readback/foreign guards");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"Store timeout state=%d status=%h",dut.state,status);end
endmodule
