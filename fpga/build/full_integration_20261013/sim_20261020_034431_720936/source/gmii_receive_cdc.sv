`timescale 1ns/1ps
// Purpose: store complete GMII wire frames before crossing unrelated 125 MHz
// clocks. Replaying a completed bank cannot insert an intra-frame gap when
// RXC is slightly slower than the DDR clock. Overflow/error drops the entire
// input frame. Banks are not reused before the consumer acknowledges them.
module gmii_receive_cdc(
 input rx_clk,rx_rst_n,input [7:0] rx_data,input rx_dv,rx_er,
 input memory_clk,memory_rst_n,output [7:0] data,output valid,output error,
 output reg [31:0] dropped_frames
);
 reg [7:0] payload[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 reg [1:0] published,acknowledged;
 reg [11:0] lengths[0:1];
 reg write_bank,read_bank,in_frame,bad;
 reg [11:0] written,read_index,read_length;
 reg running;reg [7:0] q;
 (* syn_preserve=1 *) reg [1:0] ack_meta,ack_sync,publish_meta,publish_sync;
 wire bank_free=published[write_bank]==ack_sync[write_bank];
 wire first=rx_dv && !in_frame;
 wire store=rx_dv && (first ? bank_free : !bad) && (first || written<2048) && !rx_er;
 wire [11:0] write_address={write_bank,first?11'd0:written[10:0]};
 wire launch=!running && publish_sync[read_bank]!=acknowledged[read_bank];
 wire [11:0] read_address={read_bank,launch ? 11'd0 : (read_index[10:0]+11'd1)};
 always @(posedge rx_clk)if(store)payload[write_address]<=rx_data;
 always @(posedge memory_clk)if(launch || (running && read_index<read_length-1'b1))q<=payload[read_address];
 assign data=q,valid=running,error=1'b0;
 always @(posedge rx_clk or negedge rx_rst_n)begin
  if(!rx_rst_n)begin published<=0;ack_meta<=0;ack_sync<=0;write_bank<=0;in_frame<=0;bad<=0;written<=0;
   lengths[0]<=0;lengths[1]<=0;dropped_frames<=0;end
  else begin
   ack_meta<=acknowledged;ack_sync<=ack_meta;
   if(first)begin in_frame<=1;written<=1;bad<=!bank_free || rx_er;end
   else if(rx_dv)begin
    if(written<2049)written<=written+1'b1;
    if(written>=2048 || rx_er)bad<=1;
   end
   if(!rx_dv && in_frame)begin
    in_frame<=0;
    if(!bad && written>=8 && written<=2048)begin
     lengths[write_bank]<=written;published[write_bank]<=!published[write_bank];write_bank<=!write_bank;
    end else dropped_frames<=dropped_frames+1'b1;
   end
  end
 end
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin acknowledged<=0;publish_meta<=0;publish_sync<=0;read_bank<=0;running<=0;read_index<=0;read_length<=0;end
  else begin
   publish_meta<=published;publish_sync<=publish_meta;
   if(launch)begin running<=1;read_index<=0;read_length<=lengths[read_bank];end
   if(running)begin
    if(read_index==read_length-1'b1)begin
     running<=0;acknowledged[read_bank]<=publish_sync[read_bank];read_bank<=!read_bank;
    end else read_index<=read_index+1'b1;
   end
  end
 end
endmodule
