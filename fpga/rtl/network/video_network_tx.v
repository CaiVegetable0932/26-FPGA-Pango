// Purpose: connect complete-frame PRAW packetization to the gigabit MAC queue.
// All ports use clk (125 MHz). A DDR reader may stall on pixel_ready; a live
// non-stallable DVP bus must NOT be connected directly. Peer configuration is
// frozen per frame, not re-read for each UDP packet. enable controls admission
// only: dropping it cannot truncate an already accepted Ethernet frame.
module video_network_tx #(
 parameter MAX_FRAME_BYTES=8388608, parameter INPUT_TIMEOUT=1250000
)(
 input wire clk,reset_n,enable,
 input wire frame_start,output wire frame_ready,
 input wire [63:0] stream_epoch,frame_id,
 input wire [31:0] param_version,descriptor_id,
 input wire [15:0] width,height,
 input wire [7:0] packet_type,bayer_code,
 input wire pixel_valid,pixel_last,input wire [7:0] pixel_data,
 output wire pixel_ready,
 input wire [47:0] src_mac,dst_mac,input wire [31:0] src_ip,dst_ip,
 input wire [15:0] src_port,dst_port,
 output wire [7:0] gmii_txd,output wire gmii_tx_en,gmii_tx_er,
 output wire frame_done,frame_error,output wire [3:0] error_code,
 output wire mac_busy,mac_done,mac_error,
 output wire [31:0] packets_queued,output reg [31:0] packets_sent
);
 wire core_ready,datagram_start,datagram_ready,payload_valid,payload_ready;
 wire [7:0] payload_data;wire [15:0] datagram_length;
 reg [47:0] peer_src_mac,peer_dst_mac;reg [31:0] peer_src_ip,peer_dst_ip;
 reg [15:0] peer_src_port,peer_dst_port;
 assign frame_ready=reset_n && enable && core_ready;

 // Purpose: keep destination identity stable even if software updates registers
 // during a multi-packet frame. The MAC latches these values again per packet.
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin
   peer_src_mac<=0;peer_dst_mac<=0;peer_src_ip<=0;peer_dst_ip<=0;
   peer_src_port<=0;peer_dst_port<=0;packets_sent<=0;
  end else begin
   if(frame_start && frame_ready)begin
    peer_src_mac<=src_mac;peer_dst_mac<=dst_mac;
    peer_src_ip<=src_ip;peer_dst_ip<=dst_ip;
    peer_src_port<=src_port;peer_dst_port<=dst_port;
   end
   if(mac_done)packets_sent<=packets_sent+1'b1;
  end
 end

 // Purpose: PRAW CRC, chunk geometry and frame-end checking stay independent
 // of Ethernet framing. frame_done releases a read-DMA source, not a PC receipt.
 praw_packetizer #(.MAX_FRAME_BYTES(MAX_FRAME_BYTES),.INPUT_TIMEOUT(INPUT_TIMEOUT)) u_praw(
  .clk(clk),.reset_n(reset_n),.frame_start(frame_start && frame_ready),.frame_ready(core_ready),
  .stream_epoch(stream_epoch),.frame_id(frame_id),.param_version(param_version),
  .descriptor_id(descriptor_id),.width(width),.height(height),.packet_type(packet_type),
  .bayer_code(bayer_code),.pixel_valid(pixel_valid),.pixel_last(pixel_last),
  .pixel_data(pixel_data),.pixel_ready(pixel_ready),.datagram_start(datagram_start),
  .datagram_ready(datagram_ready),.datagram_length(datagram_length),
  .payload_valid(payload_valid),.payload_ready(payload_ready),.payload_data(payload_data),
  .frame_done(frame_done),.frame_error(frame_error),.error_code(error_code),
  .packets_emitted(packets_queued));

 // Purpose: store-and-forward avoids wire underrun; UDP checksum is disabled
 // only for IPv4 while PRAW CRC, IPv4 checksum and Ethernet FCS remain enabled.
 udp_ipv4_eth_tx u_mac(
  .clk(clk),.reset_n(reset_n),.datagram_start(datagram_start),.datagram_ready(datagram_ready),
  .udp_payload_length(datagram_length),.src_mac(peer_src_mac),.dst_mac(peer_dst_mac),
  .src_ip(peer_src_ip),.dst_ip(peer_dst_ip),.src_port(peer_src_port),.dst_port(peer_dst_port),
  .payload_valid(payload_valid),.payload_ready(payload_ready),.payload_data(payload_data),
  .gmii_txd(gmii_txd),.gmii_tx_en(gmii_tx_en),.gmii_tx_er(gmii_tx_er),
  .busy(mac_busy),.done(mac_done),.error(mac_error));
endmodule
