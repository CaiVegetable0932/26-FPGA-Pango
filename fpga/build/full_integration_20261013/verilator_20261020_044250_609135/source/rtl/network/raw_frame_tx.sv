`timescale 1ns/1ps
// Immutable descriptor -> compact RAW8 or RGB888 bytes -> PRAW -> UDP.
// PIXEL_BYTES/FRAME_TYPE are explicit: RGB snapshots never impersonate S0 RAW8.
// Epoch/frame_id originate at acquisition, never at network reconnection.
// Cancellation aborts MAC, flushes bounded banks, and requests upstream DMA
// drain. release_valid is held until acknowledged and requires dma_drained.
// The upstream producer must deliver exactly WIDTH*HEIGHT effective bytes;
// missing input is bounded by INPUT_TIMEOUT cycles, not replaced by padding.
module raw_frame_tx #(
 parameter WIDTH=1920,HEIGHT=1080,INPUT_TIMEOUT=1250000,EXTERNAL_MAC=0,PACKET_BANKS=2,PIXEL_BYTES=1,FRAME_TYPE=1
)(
 input clk,input rst_n,input link_up,input peer_resolved,input cancel,
 input frame_valid,output frame_ready,input [63:0] epoch,frame_id,
 input [31:0] param_version,descriptor_id,input [7:0] bayer_code,frame_type,
 input [47:0] local_mac,peer_mac,input [31:0] local_ip,peer_ip,
 input [15:0] local_port,peer_port,
 input byte_valid,output byte_ready,input [7:0] byte_data,
 output dma_cancel,input dma_drained,
 output reg release_valid,input release_ready,output reg failed,
 output [7:0] tx_data,output tx_en,tx_er,
 output body_valid,input body_ready,output [7:0] body_data,output body_last,input external_mac_idle,
 output [31:0] sent_packets,output reg [31:0] complete_frames,failed_frames
);
 localparam FRAME_BYTES=WIDTH*HEIGHT*PIXEL_BYTES,PACKETS=(FRAME_BYTES+1399)/1400;
 reg active,feed,all_input;
 reg [63:0] saved_epoch,saved_frame;
 reg [31:0] saved_param,saved_desc,offset;
 reg [7:0] saved_bayer,saved_type;
 reg [47:0] saved_local_mac,saved_peer_mac;
 reg [31:0] saved_local_ip,saved_peer_ip;
 reg [15:0] saved_local_port,saved_peer_port,index;
 reg [10:0] payload_count,payload_size;
 reg [31:0] wait_cycles;
 reg [511:0] header;
 wire desc_ready,data_ready,packet_valid,packet_ready,packet_last,mac_idle;
 wire [7:0] packet_data;
 wire [1:0] occupied;
 wire stopping=active && (cancel || !link_up || !peer_resolved || failed || wait_cycles>=INPUT_TIMEOUT);
 assign frame_ready=!active && !release_valid && link_up && peer_resolved;
 assign byte_ready=active && feed && data_ready && !stopping;
 assign dma_cancel=stopping;
 // Header assignment at packet granularity keeps wide field muxes away from
 // the physical 125MHz byte output. All application fields are little endian.
 always @* begin
  header=0; header[0+:32]=32'h57415250;header[32+:16]=1;header[48+:16]=64;
  header[64+:8]=saved_type;header[72+:8]=(index==PACKETS-1)?2:0;header[80+:16]=PIXEL_BYTES==3 ? 2:1;
  header[96+:64]=saved_epoch;header[160+:64]=saved_frame;header[224+:32]=saved_param;
  header[256+:16]=WIDTH;header[272+:16]=HEIGHT;header[288+:32]=WIDTH*PIXEL_BYTES;
  header[320+:32]=FRAME_BYTES;header[352+:32]=offset;header[384+:16]=payload_size;
  header[400+:8]=saved_bayer;header[408+:8]=8;header[416+:16]=index;
  header[432+:16]=PACKETS;header[480+:32]=saved_desc;
 end
 praw_udp_tx #(.PACKET_BANKS(PACKET_BANKS)) packets(.clk(clk),.rst_n(rst_n),.flush(stopping),
  .desc_valid(active && !feed && !all_input && !stopping),.desc_ready(desc_ready),
  .praw_header(header),.payload_bytes(payload_size),.local_mac(saved_local_mac),.peer_mac(saved_peer_mac),
  .local_ip(saved_local_ip),.peer_ip(saved_peer_ip),.local_port(saved_local_port),.peer_port(saved_peer_port),
  .data_valid(byte_valid && byte_ready),.data_ready(data_ready),.data(byte_data),
  .out_valid(packet_valid),.out_ready(packet_ready),.out_data(packet_data),.out_last(packet_last),
  .prepared_packets(),.sent_packets(sent_packets),.rejected(),.occupied(occupied));
 assign body_valid=packet_valid;assign body_data=packet_data;assign body_last=packet_last;
 generate if(EXTERNAL_MAC) begin: external_output
  assign packet_ready=body_ready;assign mac_idle=external_mac_idle;
  assign tx_data=0;assign tx_en=0;assign tx_er=0;
 end else begin: internal_output
  ethernet_mac_tx mac(.clk(clk),.rst_n(rst_n),.link_up(link_up && !stopping),
   .in_valid(packet_valid),.in_ready(packet_ready),.in_data(packet_data),.in_last(packet_last),
   .tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),.idle(mac_idle),.frames(),.underruns());
 end endgenerate
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   active<=0;feed<=0;all_input<=0;release_valid<=0;failed<=0;offset<=0;index<=0;
   payload_count<=0;payload_size<=0;wait_cycles<=0;complete_frames<=0;failed_frames<=0;
   saved_epoch<=0;saved_frame<=0;saved_param<=0;saved_desc<=0;saved_bayer<=0;saved_type<=0;
   saved_local_mac<=0;saved_peer_mac<=0;saved_local_ip<=0;saved_peer_ip<=0;
   saved_local_port<=0;saved_peer_port<=0;
  end else begin
   if(release_valid && release_ready) release_valid<=0;
   if(frame_valid && frame_ready) begin
    active<=1;feed<=0;all_input<=0;offset<=0;index<=0;payload_count<=0;wait_cycles<=0;
    payload_size<=(FRAME_BYTES>1400)?1400:FRAME_BYTES;
    saved_epoch<=epoch;saved_frame<=frame_id;saved_param<=param_version;saved_desc<=descriptor_id;
    saved_bayer<=bayer_code;saved_type<=FRAME_TYPE==0 ? frame_type:FRAME_TYPE;saved_local_mac<=local_mac;saved_peer_mac<=peer_mac;
    saved_local_ip<=local_ip;saved_peer_ip<=peer_ip;saved_local_port<=local_port;saved_peer_port<=peer_port;
    failed<=epoch==0 || (PIXEL_BYTES==1 && (bayer_code<1 || bayer_code>4)) || (PIXEL_BYTES==3 && (bayer_code!=0 || (FRAME_TYPE==0 && frame_type!=2 && frame_type!=3))) || local_port==0 || peer_port==0;
   end
   if(active && !stopping) begin
    if(!feed && !all_input && desc_ready) begin feed<=1;payload_count<=0;end
    // Timeout measures missing source service only; packet-bank backpressure is
    // governed by finite complete packets and MAC service, never by source age.
    if(byte_ready && !byte_valid) wait_cycles<=wait_cycles+1;
    else if(byte_valid && byte_ready) begin
     wait_cycles<=0;
     if(payload_count==payload_size-1) begin
      feed<=0;offset<=offset+payload_size;index<=index+1'b1;
      // All packets except the known last one are 1400B. Register this field
      // at the packet boundary, removing offset subtract -> IP checksum from
      // the preparation critical path without changing payload or packet rate.
      payload_size<=(index==PACKETS-2)?(FRAME_BYTES-(PACKETS-1)*1400):1400;
      if(index==PACKETS-1) all_input<=1;
     end else payload_count<=payload_count+1'b1;
    end
    if(all_input && occupied==0 && mac_idle && dma_drained) begin
     active<=0;release_valid<=1;failed<=0;complete_frames<=complete_frames+1;
    end
   end
   if(stopping) begin
    failed<=1;feed<=0;
    if(dma_drained && mac_idle) begin active<=0;release_valid<=1;failed_frames<=failed_frames+1;end
   end
  end
 end
endmodule
