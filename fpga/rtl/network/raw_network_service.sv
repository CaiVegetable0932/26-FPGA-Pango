`timescale 1ns/1ps
// Section 07 single-clock protocol integration. The RAW DMA byte producer and
// source slot owner are external (sections 04/03); all GMII ports share clk.
// RGMII PHY IO, verified asynchronous descriptor transfer, PHY delay/MDIO/link
// polling belong to board integration. This module does not infer link from LEDs.
module raw_network_service #(
 parameter WIDTH=1920,HEIGHT=1080,PACKET_BANKS=2,CONFIGURED_PEER=0
)(
 input clk,input rst_n,input [63:0] now_us,input gigabit_link_up,input resolve,input cancel,
 input [47:0] local_mac,input [31:0] local_ip,peer_ip,input [15:0] local_port,peer_port,
 input [47:0] configured_peer_mac,
 input [7:0] rx_data,input rx_dv,rx_er,output [7:0] tx_data,output tx_en,tx_er,
 input frame_valid,output frame_ready,input [63:0] epoch,frame_id,
 input [31:0] param_version,descriptor_id,input [7:0] bayer_code,
 input byte_valid,output byte_ready,input [7:0] byte_data,
 output dma_cancel,input dma_drained,output release_valid,input release_ready,output failed,
 output peer_valid,output resolution_failed,output [31:0] sent_packets,complete_frames,failed_frames
);
 // An immutable explicit boot peer preserves historical PC commissioning.
 // Standalone protocol users retain bounded ARP resolution by default.
 wire [47:0] learned_peer_mac;
 wire learned_peer_valid;
 wire [47:0] peer_mac=CONFIGURED_PEER ? configured_peer_mac:learned_peer_mac;
 // Boot MAC is immutable before link commissioning. Register its explicit
 // presence instead of propagating a 48-bit compare through cancellation,
 // arbitration and unrelated geometry ownership on the same DDR edge.
 reg configured_peer_present;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)configured_peer_present<=0;
  else configured_peer_present<=gigabit_link_up && configured_peer_mac!=0;
 end
 assign peer_valid=CONFIGURED_PEER ? configured_peer_present:learned_peer_valid;
 wire rx_valid,rx_ready,rx_last;wire [7:0] rx_body;
 wire ctrl_valid,ctrl_ready,ctrl_last;wire [7:0] ctrl_data;
 wire raw_valid,raw_ready,raw_last;wire [7:0] raw_data;
 wire mac_valid,mac_ready,mac_last,mac_idle,raw_selected;wire [7:0] mac_data;
 ethernet_mac_rx rx(.clk(clk),.rst_n(rst_n),.link_up(gigabit_link_up),
  .rx_data(rx_data),.rx_dv(rx_dv),.rx_er(rx_er),.out_valid(rx_valid),.out_ready(rx_ready),
  .out_data(rx_body),.out_last(rx_last),.good_frames(),.bad_frames(),.overruns());
 assign rx_ready=1;
 arp_peer arp(.clk(clk),.rst_n(rst_n),.now_us(now_us),.link_up(gigabit_link_up),.resolve(resolve),
  .local_mac(local_mac),.local_ip(local_ip),.peer_ip(peer_ip),
  .rx_valid(rx_valid),.rx_data(rx_body),.rx_last(rx_last),.rx_packet_good(1'b1),
  .peer_valid(learned_peer_valid),.peer_mac(learned_peer_mac),.resolution_failed(resolution_failed),
  .tx_valid(ctrl_valid),.tx_ready(ctrl_ready),.tx_data(ctrl_data),.tx_last(ctrl_last),
  .rejected_rx(),.dropped_replies(),.requests());
 raw_frame_tx #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.EXTERNAL_MAC(1),.PACKET_BANKS(PACKET_BANKS)) raw(
  .clk(clk),.rst_n(rst_n),.link_up(gigabit_link_up),.peer_resolved(peer_valid),.cancel(cancel),
  .frame_valid(frame_valid),.frame_ready(frame_ready),.epoch(epoch),.frame_id(frame_id),
  .param_version(param_version),.descriptor_id(descriptor_id),.bayer_code(bayer_code),
  .local_mac(local_mac),.peer_mac(peer_mac),.local_ip(local_ip),.peer_ip(peer_ip),.local_port(local_port),.peer_port(peer_port),
  .byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data),.dma_cancel(dma_cancel),.dma_drained(dma_drained),
  .release_valid(release_valid),.release_ready(release_ready),.failed(failed),.tx_data(),.tx_en(),.tx_er(),
  .body_valid(raw_valid),.body_ready(raw_ready),.body_data(raw_data),.body_last(raw_last),.external_mac_idle(mac_idle),
  .sent_packets(sent_packets),.complete_frames(complete_frames),.failed_frames(failed_frames));
 // Packets use ONLY the same peer MAC/IP supplied by the immutable PC boot
 // entity. This RTL has no default remote endpoint or autonomous uploader.
 // RAW and ARP retain packet-boundary arbitration and cancellation draining.
 ethernet_packet_mux arb(.clk(clk),.rst_n(rst_n),.cancel_raw(dma_cancel),
  .raw_valid(raw_valid),.raw_ready(raw_ready),.raw_data(raw_data),.raw_last(raw_last),
  .control_valid(ctrl_valid),.control_ready(ctrl_ready),.control_data(ctrl_data),.control_last(ctrl_last),
  .out_valid(mac_valid),.out_ready(mac_ready),.out_data(mac_data),.out_last(mac_last),.raw_selected(raw_selected));
 ethernet_mac_tx tx(.clk(clk),.rst_n(rst_n),.link_up(gigabit_link_up && !(raw_selected && dma_cancel)),
  .in_valid(mac_valid),.in_ready(mac_ready),.in_data(mac_data),.in_last(mac_last),
  .tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),.idle(mac_idle),.frames(),.underruns());
endmodule
