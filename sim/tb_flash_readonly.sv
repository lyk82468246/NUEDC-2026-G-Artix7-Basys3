`timescale 1ns/1ps
// Read-only SPI slave checks the ACTUAL SCK/CS/MOSI wires. Any write opcode
// fails immediately. Memory layout includes the physical commit-page gap.
module tb_flash_readonly #(parameter EXPECTED=24'hc22016,BUSY_POLLS=2);
    reg clk=0,por=1,reload=0,accept=0;
    always #5 clk=~clk;
    wire cs,sck,mosi,miso,ready,valid,record_valid,busy;
    wire [96:0] bank;
    wire [31:0] seq,epoch;
    wire [1:0] source;
    wire [3:0] error;
    wire [23:0] jedec;wire [7:0] sr;
    Calibration_Flash_Restore #(.EXPECTED_JEDEC(EXPECTED),.HALF_PERIOD(2),.POLL_GAP(4),.MAX_POLLS(3)) dut(
        .clk(clk),.por(por),.reload_valid(reload),.reload_ready(ready),
        .out_valid(valid),.out_ready(accept),.record_valid(record_valid),.bank(bank),
        .record_sequence(seq),.saved_epoch(epoch),.source(source),.error_code(error),
        .jedec_id(jedec),.status_register(sr),.busy(busy),.cs_n(cs),.sck(sck),.mosi(mosi),.miso(miso));
    reg [7:0] memory[0:159];
    reg [7:0] received=0,opcode=0,response=8'hff;
    integer bit_count=0,byte_count=0,read_commands=0,remaining_busy=BUSY_POLLS;
    reg [23:0] address=0;
    assign miso=cs?1'b1:response[7-bit_count];
    function [7:0] at_address(input [23:0] a);
        begin
            if(a>=24'h3e0000 && a<24'h3e0040)at_address=memory[a-24'h3e0000];
            else if(a>=24'h3e0100 && a<24'h3e0110)at_address=memory[64+a-24'h3e0100];
            else if(a>=24'h3f0000 && a<24'h3f0040)at_address=memory[80+a-24'h3f0000];
            else if(a>=24'h3f0100 && a<24'h3f0110)at_address=memory[144+a-24'h3f0100];
            else at_address=8'hff; // unused next-byte prefetch after the last clock
        end
    endfunction
    always @(negedge cs)begin bit_count=0;byte_count=0;received=0;response=8'hff;address=0;end
    always @(posedge sck)if(!cs)begin
        received={received[6:0],mosi};
        if(bit_count==7)begin
            if(byte_count==0)begin
                opcode=received;
                assert(opcode==8'h9f || opcode==8'h05 || opcode==8'h03)
                    else $fatal(1,"UNSAFE opcode %h",opcode);
                if(opcode==8'h03)read_commands=read_commands+1;
            end else if(opcode==8'h03)begin
                if(byte_count<=3)address={address[15:0],received};else address=address+1;
            end
            byte_count=byte_count+1;bit_count=0;received=0;
            case(opcode)
                8'h9f:case(byte_count)1:response=8'hc2;2:response=8'h20;3:response=8'h16;default:response=8'hff;endcase
                8'h05:begin response=remaining_busy>0?8'h41:8'h40;if(byte_count==1 && remaining_busy>0)remaining_busy=remaining_busy-1;end
                8'h03:response=byte_count>=4?at_address(address):8'hff;
            endcase
        end else bit_count=bit_count+1;
    end
    task take_result;
        reg [167:0] held;
        begin
            wait(valid);@(negedge clk);held={record_valid,source,error,bank,seq,epoch};
            repeat(13)begin @(negedge clk);assert(valid && held=={record_valid,source,error,bank,seq,epoch})
                else $fatal(1,"Result changed under backpressure");end
            accept=1;@(negedge clk);accept=0;wait(ready);
        end
    endtask
    task restart;
        begin wait(ready);@(negedge clk);reload=1;@(negedge clk);reload=0;wait(valid);end
    endtask
    initial begin
        $readmemh("flash_valid.mem",memory);
        repeat(5)@(negedge clk);por=0;
        wait(valid);
        if(BUSY_POLLS>2)begin
            assert(!record_valid && error==1 && read_commands==0)else $fatal(1,"WIP timeout");take_result();
        end else if(EXPECTED==0)begin
            assert(jedec==24'hc22016 && !record_valid && error==2 && read_commands==0)
                else $fatal(1,"Unknown profile touched array");take_result();
        end else begin
            assert(record_valid && source==2 && error==0 && seq==0 && epoch==12 &&
                bank=={1'b1,32'd3600000,32'd3750000,32'd4200} && sr==8'h40)else $fatal(1,"Wrap selection/B bank");take_result();
            $readmemh("flash_bad_b.mem",memory);restart();
            assert(record_valid && source==1 && seq==32'hffffffff && epoch==11)else $fatal(1,"Bad B accepted");take_result();
            $readmemh("flash_conflict.mem",memory);restart();
            assert(!record_valid && source==3 && error==4)else $fatal(1,"Conflict not rejected");take_result();
            $readmemh("flash_blank.mem",memory);restart();
            assert(!record_valid && source==0 && error==3)else $fatal(1,"Blank fallback");take_result();
        end
        $display("PASS: physical SPI read-only restore, CRC/commit, sequence wrap/conflict, blank/unknown/WIP timeout, backpressure");
        $finish;
    end
    initial begin #10000000;$fatal(1,"Flash restore timeout state=%d",dut.state);end
endmodule
module tb_flash_unknown;tb_flash_readonly #(.EXPECTED(0)) t();endmodule
module tb_flash_busy;tb_flash_readonly #(.BUSY_POLLS(5)) t();endmodule
