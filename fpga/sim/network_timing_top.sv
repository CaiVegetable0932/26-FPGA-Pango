`timescale 1ns/1ps
// Isolated PDS timing fixture, not a board top or UART configuration protocol.
// Serial fixture loading retains dynamic descriptor/endpoints without exporting
// 548 logical bus bits as physical package pins. Configuration stays stable
// during transactions. Real byte/GMII/service/release logic is unchanged.
module network_timing_top(
 input clk,input rst_n,input link_up,resolve,cancel,
 input cfg_shift,input [7:0] cfg_byte,
 input [7:0] rx_data,input rx_dv,rx_er,input frame_valid,
 input byte_valid,input [7:0] byte_data,input dma_drained,release_ready,
 output [7:0] tx_data,output tx_en,tx_er,frame_ready,byte_ready,dma_cancel,release_valid,failed,
 output [31:0] observe
);
 reg [511:0] cfg;reg [6:0] tick_div;reg [63:0] now_us;
 wire [31:0] packets,complete_frames,failed_frames;wire peer_valid,resolution_failed;
 always @(posedge clk) if(cfg_shift) cfg<={cfg[503:0],cfg_byte};
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin tick_div<=0;now_us<=0;end
  else if(tick_div==124) begin tick_div<=0;now_us<=now_us+1'b1;end else tick_div<=tick_div+1'b1;
 end
 raw_network_service service(.clk(clk),.rst_n(rst_n),.now_us(now_us),.gigabit_link_up(link_up),.resolve(resolve),.cancel(cancel),
  .local_mac(cfg[0+:48]),.local_ip(cfg[96+:32]),.peer_ip(cfg[128+:32]),.local_port(cfg[160+:16]),.peer_port(cfg[176+:16]),
  .rx_data(rx_data),.rx_dv(rx_dv),.rx_er(rx_er),.tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),
  .frame_valid(frame_valid),.frame_ready(frame_ready),.epoch(cfg[192+:64]),.frame_id(cfg[256+:64]),
  .param_version(cfg[320+:32]),.descriptor_id(cfg[352+:32]),.bayer_code(cfg[384+:8]),
  .byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data),.dma_cancel(dma_cancel),.dma_drained(dma_drained),
  .release_valid(release_valid),.release_ready(release_ready),.failed(failed),.peer_valid(peer_valid),.resolution_failed(resolution_failed),
  .sent_packets(packets),.complete_frames(complete_frames),.failed_frames(failed_frames));
 assign observe=packets^complete_frames^failed_frames^{30'd0,peer_valid,resolution_failed};
endmodule
