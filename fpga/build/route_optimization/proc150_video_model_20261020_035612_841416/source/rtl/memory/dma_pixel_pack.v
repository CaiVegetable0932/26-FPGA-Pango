`timescale 1ns/1ps
// Purpose: pack RAW8 or RGB888 pixels into masked 32-byte DDR beats.
// RGB byte order is pixel[7:0], [15:8], [23:16]; stage decides channel order.
// start_offset is the BYTE offset in the aligned first beat. Rows/tile segments
// flush independently; neither stride padding nor adjacent tiles are written.
// Ready/valid source is required; an unpausable DVP needs a separate CDC FIFO.
module dma_pixel_pack(
 input clk,input rst_n,input start_valid,output start_ready,
 input [4:0] start_offset,input rgb888,
 input pixel_valid,output pixel_ready,input [23:0] pixel,input pixel_last,
 output beat_valid,input beat_ready,output [255:0] beat_data,
 output [31:0] beat_strb,output beat_last
);
 reg active,flushing,mode;
 reg [5:0] count;
 reg [279:0] bytes_q,bytes_next;
 reg [34:0] mask_q,mask_next;
 reg [5:0] count_next;
 assign start_ready=!active;
 assign beat_valid=active && (count>=32 || (flushing && count!=0));
 assign beat_data=bytes_q[255:0],beat_strb=mask_q[31:0];
 assign beat_last=flushing && count<=32;
 assign pixel_ready=active && !flushing && (count<32 || beat_ready);
 // Purpose: drain and append on the original edge with fixed byte
 // lanes. The pre-append cursor is bounded to 0..31 when accepting a pixel;
 // 35 storage lanes still preserve the two/three-byte RGB overflow payload.
 wire take_beat=beat_valid && beat_ready;
 wire take_pixel=pixel_valid && pixel_ready;
 wire [5:0] append_at=take_beat ? ((count>=32)?count-6'd32:6'd0) : count;
 integer lane;
 always @* begin
  bytes_next=take_beat ? (bytes_q>>256) : bytes_q;
  mask_next=take_beat ? (mask_q>>32) : mask_q;
  count_next=append_at;
  for(lane=0;lane<35;lane=lane+1)begin
   if(take_pixel && append_at==lane)begin
    bytes_next[lane*8+:8]=pixel[7:0];mask_next[lane]=1;
   end
   if(take_pixel && mode && append_at+6'd1==lane)begin
    bytes_next[lane*8+:8]=pixel[15:8];mask_next[lane]=1;
   end
   if(take_pixel && mode && append_at+6'd2==lane)begin
    bytes_next[lane*8+:8]=pixel[23:16];mask_next[lane]=1;
   end
  end
  if(take_pixel)count_next=append_at+(mode?6'd3:6'd1);
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active<=0; flushing<=0; mode<=0; count<=0; bytes_q<=0; mask_q<=0; end
  else begin
   if(start_valid && start_ready) begin
    active<=1; flushing<=0; mode<=rgb888; count<={1'b0,start_offset}; bytes_q<=0; mask_q<=0;
   end else begin
    bytes_q<=bytes_next; mask_q<=mask_next; count<=count_next;
    if(pixel_valid && pixel_ready && pixel_last) flushing<=1;
    if(beat_valid && beat_ready && beat_last) begin active<=0; flushing<=0; end
   end
  end
 end
endmodule
