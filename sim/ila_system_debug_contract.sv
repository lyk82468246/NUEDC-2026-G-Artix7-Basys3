// SIMULATION-ONLY port contract. Never register in synthesis filesets.
// This does NOT model ILA storage or vendor IP implementation.
module ila_system(input clk,input [0:0] probe0,input [16:0] probe1,
    input [15:0] probe2,input [31:0] probe3,input [11:0] probe4,
    input [4:0] probe5,input [31:0] probe6,input [11:0] probe7,
    input [35:0] probe8,input [31:0] probe9,input [95:0] probe10,
    input [1:0] probe11,input [31:0] probe12,input [31:0] probe13,input [7:0] probe14);
endmodule
