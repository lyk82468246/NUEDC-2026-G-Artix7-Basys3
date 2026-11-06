`timescale 1ns/1ps
// Input-only protocol substitutes. No FFT/CORDIC numeric or output behavior.
// The separate real-IP regression verifies complete FFT output progress.
module xfft_8192(
 input aclk,aresetn,input [7:0] s_axis_config_tdata,input s_axis_config_tvalid,
 output s_axis_config_tready,input [31:0] s_axis_data_tdata,input s_axis_data_tvalid,s_axis_data_tlast,
 output s_axis_data_tready,output [63:0] m_axis_data_tdata,output m_axis_data_tvalid,m_axis_data_tlast,
 input m_axis_data_tready,output event_frame_started,event_tlast_unexpected,event_tlast_missing,
 output event_status_channel_halt,event_data_in_channel_halt,event_data_out_channel_halt
);
 reg [15:0] tick=0;always @(posedge aclk)if(!aresetn)tick<=0;else tick<=tick+1'b1;
 assign s_axis_config_tready=aresetn && tick%5==4;
 assign s_axis_data_tready=aresetn && tick%9>=4;
 assign m_axis_data_tdata=0;assign m_axis_data_tvalid=0;assign m_axis_data_tlast=0;
 assign event_frame_started=0;assign event_tlast_unexpected=0;assign event_tlast_missing=0;
 assign event_status_channel_halt=0;assign event_data_in_channel_halt=0;assign event_data_out_channel_halt=0;
endmodule
module cordic_translate_mag(
 input aclk,aresetn,input s_axis_cartesian_tvalid,input [63:0] s_axis_cartesian_tdata,
 output s_axis_cartesian_tready,output m_axis_dout_tvalid,input m_axis_dout_tready,
 output [63:0] m_axis_dout_tdata
);
 assign s_axis_cartesian_tready=aresetn;assign m_axis_dout_tvalid=0;assign m_axis_dout_tdata=0;
endmodule
