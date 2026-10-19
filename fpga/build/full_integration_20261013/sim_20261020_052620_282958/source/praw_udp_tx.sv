`timescale 1ns/1ps
// Two bounded packet banks overlap preparation with transmission. The supplied
// 64B PRAW header is little endian, CRC bytes 56..59 must be zero. This engine
// computes header+payload ISO-HDLC CRC and mandatory IPv4 UDP checksum BEFORE
// publishing a bank. MAC may start only on a published complete packet.
// All ports share clk; no CDC is implied. Addresses/MACs are explicit inputs.
module praw_udp_tx #(parameter PACKET_BANKS=2)(
 input clk, input rst_n, input flush,
 input desc_valid, output desc_ready, input [511:0] praw_header,
 input [10:0] payload_bytes, input [47:0] local_mac, peer_mac,
 input [31:0] local_ip, peer_ip, input [15:0] local_port, peer_port,
 input data_valid, output data_ready, input [7:0] data,
 output out_valid, input out_ready, output reg [7:0] out_data,
 output out_last, output reg [31:0] prepared_packets, sent_packets,
 output reg [31:0] rejected, output [1:0] occupied
);
 reg [7:0] mem [0:4095]; // 2 x 2048; no reset on RAM storage.
 reg [335:0] net_header [0:1];
 reg [31:0] app_crc [0:1];
 reg [10:0] lengths [0:1];
 reg [1:0] used, published;
 reg wr_bank, rd_bank, preparing, sending;
 reg [10:0] wp, rp, target;
 reg [511:0] saved_header;
 reg [31:0] crc, udp_sum;
 reg [7:0] high_byte;
 reg finalize;
 reg [31:0] base_sum;
 reg [15:0] udp_length, ip_length;
 reg [335:0] header_work;
 wire [7:0] incoming=(wp<64) ? saved_header[wp*8+:8] : data;
 wire accept=preparing && !finalize && (wp<64 || (data_valid && data_ready));
 assign desc_ready=!flush && !preparing && !used[wr_bank];
 assign data_ready=preparing && !finalize && wp>=64 && !flush;
 assign out_valid=sending;
 assign out_last=sending && rp==lengths[rd_bank]+41;
 assign occupied={1'b0,used[0]}+{1'b0,used[1]};
 // Reflected CRC is byte-parallel, independent from UART CRC16.
 function automatic [31:0] crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v; integer i;
  begin v=c^b; for(i=0;i<8;i=i+1) v=(v>>1)^(v[0]?32'hedb88320:0); crc_byte=v; end
 endfunction
 function automatic [15:0] checksum(input [31:0] s);
  reg [31:0] t;
  begin t=(s&65535)+(s>>16); t=(t&65535)+(t>>16); checksum=~t[15:0]; end
 endfunction
 // Read address is clocked; output remains unchanged on backpressure. Ethernet
 // header bytes and the CRC patch are selected outside the packet RAM contents.
 function automatic [7:0] read_byte(input bank,input [10:0] pos);
  begin
   if(pos<42) read_byte=net_header[bank][pos*8+:8];
   else if(pos>=98 && pos<102) read_byte=app_crc[bank][(pos-98)*8+:8];
   else read_byte=mem[{bank,11'd0}+pos-42];
  end
 endfunction
 integer i;
 reg [31:0] patched_sum;
 reg [15:0] udp_check, ip_check;
 // Prepare network-order fixed headers with zero checksum slots. No endpoint
 // is invented here; the integration must freeze endpoints for the session.
 always @* begin
  udp_length=payload_bytes+16'd72; ip_length=payload_bytes+16'd92;
  header_work=0;
  for(i=0;i<6;i=i+1) begin
   header_work[i*8+:8]=peer_mac[(5-i)*8+:8];
   header_work[(i+6)*8+:8]=local_mac[(5-i)*8+:8];
  end
  header_work[12*8+:8]=8'h08; header_work[13*8+:8]=0;
  header_work[14*8+:8]=8'h45;
  header_work[16*8+:8]=ip_length[15:8]; header_work[17*8+:8]=ip_length[7:0];
  header_work[20*8+:8]=8'h40; // DF, no fragmentation, ID=0.
  header_work[22*8+:8]=64; header_work[23*8+:8]=17;
  for(i=0;i<4;i=i+1) begin
   header_work[(26+i)*8+:8]=local_ip[(3-i)*8+:8];
   header_work[(30+i)*8+:8]=peer_ip[(3-i)*8+:8];
  end
  ip_check=checksum(32'h4500+ip_length+32'h4000+32'h4011+
    local_ip[31:16]+local_ip[15:0]+peer_ip[31:16]+peer_ip[15:0]);
  header_work[24*8+:8]=ip_check[15:8]; header_work[25*8+:8]=ip_check[7:0];
  header_work[34*8+:8]=local_port[15:8]; header_work[35*8+:8]=local_port[7:0];
  header_work[36*8+:8]=peer_port[15:8]; header_work[37*8+:8]=peer_port[7:0];
  header_work[38*8+:8]=udp_length[15:8]; header_work[39*8+:8]=udp_length[7:0];
  base_sum={16'd0,local_ip[31:16]}+local_ip[15:0]+peer_ip[31:16]+peer_ip[15:0]+
   17+udp_length+local_port+peer_port+udp_length;
  patched_sum=udp_sum+{app_crc[wr_bank][7:0],app_crc[wr_bank][15:8]}+
   {app_crc[wr_bank][23:16],app_crc[wr_bank][31:24]};
  udp_check=checksum(patched_sum);
  if(udp_check==0) udp_check=16'hffff;
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   used<=0; published<=0; wr_bank<=0; rd_bank<=0; preparing<=0; sending<=0;
   wp<=0; rp<=0; target<=0; saved_header<=0; crc<=0; udp_sum<=0;
   high_byte<=0; finalize<=0; out_data<=0;
   prepared_packets<=0; sent_packets<=0; rejected<=0;
  end else if(flush) begin
   // Caller may flush only when MAC is idle or has aborted the physical frame.
   used<=0; published<=0; preparing<=0; sending<=0; wr_bank<=0; rd_bank<=0;
   finalize<=0;
  end else begin
   if(desc_valid && desc_ready) begin
    if(payload_bytes==0 || payload_bytes>1400 || praw_header[56*8+:32]!=0 ||
       praw_header[48*8+:16]!=payload_bytes) rejected<=rejected+1;
    else begin
     preparing<=1; used[wr_bank]<=1; saved_header<=praw_header;
     wp<=0; target<=payload_bytes+64; crc<=32'hffffffff; udp_sum<=base_sum;
     finalize<=0; lengths[wr_bank]<=payload_bytes+64; net_header[wr_bank]<=header_work;
    end
   end
   if(accept) begin
    mem[{wr_bank,11'd0}+wp]<=incoming;
    crc<=crc_byte(crc,incoming);
    if(!wp[0]) high_byte<=incoming;
    else udp_sum<=udp_sum+{high_byte,incoming};
    if(wp==target-1) begin
     app_crc[wr_bank]<=~crc_byte(crc,incoming);
     if(!wp[0]) udp_sum<=udp_sum+{incoming,8'd0};
     finalize<=1;
    end else wp<=wp+1'b1;
   end
   if(preparing && finalize) begin
    net_header[wr_bank][40*8+:8]<=udp_check[15:8];
    net_header[wr_bank][41*8+:8]<=udp_check[7:0];
    preparing<=0; finalize<=0; published[wr_bank]<=1; wr_bank<=(PACKET_BANKS==1)?0:!wr_bank;
    prepared_packets<=prepared_packets+1;
   end
   if(!sending && published[rd_bank]) begin
    sending<=1; rp<=0; out_data<=read_byte(rd_bank,0);
   end else if(out_valid && out_ready) begin
    if(out_last) begin
     sending<=0; used[rd_bank]<=0; published[rd_bank]<=0; rd_bank<=(PACKET_BANKS==1)?0:!rd_bank;
     sent_packets<=sent_packets+1;
    end else begin rp<=rp+1'b1; out_data<=read_byte(rd_bank,rp+1'b1); end
   end
  end
 end
endmodule
