`timescale 1ns/1ps
// One-peer direct-link ARP, no unbounded cache or retry queue. Ethernet RX body
// must be committed after MAC FCS verification by rx_packet_good. Up to 3 ARP
// requests per resolution round; explicit failure requires a new resolve pulse.
// Requests addressed to local IP receive one bounded reply; full reply slot
// drops and counts. Raw packet arbitration must give control a bounded quota.
module arp_peer #(parameter RETRY_US=100000,TTL_US=30000000)(
 input clk,input rst_n,input [63:0] now_us,input link_up,input resolve,
 input [47:0] local_mac,input [31:0] local_ip,peer_ip,
 input rx_valid,input [7:0] rx_data,input rx_last,input rx_packet_good,
 output reg peer_valid,output reg [47:0] peer_mac,output reg resolution_failed,
 output tx_valid,input tx_ready,output [7:0] tx_data,output tx_last,
 output reg [31:0] rejected_rx,dropped_replies,requests
);
 reg [335:0] rx_header,tx_header;
 reg [10:0] rx_pos;reg [5:0] tx_pos;
 reg tx_active,waiting;reg [1:0] attempts;
 reg [63:0] deadline,expires;
 reg reply_pending;reg [47:0] reply_mac;reg [31:0] reply_ip;
 // Capture exactly the ARP header, tolerate only normal Ethernet padding.
 wire [335:0] current_rx=rx_pos<42 ?
   (rx_header & ~(336'hff<<(rx_pos*8))) | ({328'd0,rx_data}<<(rx_pos*8)) : rx_header;
 function automatic [47:0] mac_at(input [335:0] h,input integer base);
  integer i;begin for(i=0;i<6;i=i+1) mac_at[(5-i)*8+:8]=h[(base+i)*8+:8];end
 endfunction
 function automatic [31:0] ip_at(input [335:0] h,input integer base);
  integer i;begin for(i=0;i<4;i=i+1) ip_at[(3-i)*8+:8]=h[(base+i)*8+:8];end
 endfunction
 wire [47:0] sender_mac=mac_at(current_rx,22),destination=mac_at(current_rx,0);
 wire [31:0] sender_ip=ip_at(current_rx,28),target_ip=ip_at(current_rx,38);
 wire layout_ok=rx_packet_good && rx_pos>=41 && rx_pos<1518 &&
  current_rx[96+:16]==16'h0608 && current_rx[112+:16]==16'h0100 &&
  current_rx[128+:16]==16'h0008 && current_rx[144+:8]==6 && current_rx[152+:8]==4 &&
  sender_mac!=0 && !sender_mac[40] && mac_at(current_rx,6)==sender_mac &&
  (destination==local_mac || destination==48'hffffffffffff);
 assign tx_valid=tx_active;
 assign tx_data=tx_header[tx_pos*8+:8];assign tx_last=tx_active && tx_pos==41;
 task automatic build(input reply,input [47:0] dst,input [31:0] dst_ip);
  reg [335:0] h;integer j;
  begin
   h=0;
   for(j=0;j<6;j=j+1) begin
    h[j*8+:8]=dst[(5-j)*8+:8];h[(6+j)*8+:8]=local_mac[(5-j)*8+:8];
    h[(22+j)*8+:8]=local_mac[(5-j)*8+:8];h[(32+j)*8+:8]=reply?dst[(5-j)*8+:8]:0;
   end
   h[96+:16]=16'h0608;h[112+:16]=16'h0100;h[128+:16]=16'h0008;
   h[144+:8]=6;h[152+:8]=4;h[160+:16]=reply?16'h0200:16'h0100;
   for(j=0;j<4;j=j+1) begin h[(28+j)*8+:8]=local_ip[(3-j)*8+:8];h[(38+j)*8+:8]=dst_ip[(3-j)*8+:8];end
   tx_header<=h;tx_pos<=0;tx_active<=1;
  end
 endtask
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   rx_header<=0;tx_header<=0;rx_pos<=0;tx_pos<=0;tx_active<=0;waiting<=0;attempts<=0;
   deadline<=0;expires<=0;reply_pending<=0;reply_mac<=0;reply_ip<=0;
   peer_valid<=0;peer_mac<=0;resolution_failed<=0;rejected_rx<=0;dropped_replies<=0;requests<=0;
  end else if(!link_up) begin
   peer_valid<=0;waiting<=0;tx_active<=0;reply_pending<=0;rx_pos<=0;resolution_failed<=0;
  end else begin
   if(peer_valid && now_us>=expires) peer_valid<=0;
   if(resolve && !waiting && !peer_valid) begin waiting<=1;attempts<=0;deadline<=now_us;resolution_failed<=0;end
   if(tx_active && tx_ready) begin if(tx_last) tx_active<=0;else tx_pos<=tx_pos+1'b1;end
   if(!tx_active) begin
    if(reply_pending) begin build(1,reply_mac,reply_ip);reply_pending<=0;end
    else if(waiting && now_us>=deadline) begin
     if(attempts==3) begin waiting<=0;resolution_failed<=1;end
     else begin build(0,48'hffffffffffff,peer_ip);attempts<=attempts+1'b1;requests<=requests+1;deadline<=now_us+RETRY_US;end
    end
   end
   if(rx_valid) begin
    if(rx_pos<42) rx_header<=current_rx;
    if(rx_last) begin
     rx_pos<=0;
     if(!layout_ok || target_ip!=local_ip) rejected_rx<=rejected_rx+1;
     else if(current_rx[160+:16]==16'h0200 && waiting && sender_ip==peer_ip &&
             mac_at(current_rx,32)==local_mac && destination==local_mac) begin
      peer_mac<=sender_mac;peer_valid<=1;waiting<=0;expires<=now_us+TTL_US;resolution_failed<=0;
     end else if(current_rx[160+:16]==16'h0100) begin
      if(reply_pending) dropped_replies<=dropped_replies+1;
      else begin reply_pending<=1;reply_mac<=sender_mac;reply_ip<=sender_ip;end
     end else rejected_rx<=rejected_rx+1;
    end else if(rx_pos<2047) rx_pos<=rx_pos+1'b1;
   end
  end
 end
endmodule
