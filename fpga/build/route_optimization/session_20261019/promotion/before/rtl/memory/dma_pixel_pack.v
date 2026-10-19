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
 // Purpose: remove a beat and append up to three bytes in the same cycle;
 // the 35-byte reservoir preserves RGB pixels straddling a 32-byte boundary.
 always @* begin
  bytes_next=bytes_q; mask_next=mask_q; count_next=count;
  if(beat_valid && beat_ready) begin
   bytes_next=bytes_q>>256; mask_next=mask_q>>32;
   count_next=(count>=32) ? count-32 : 0;
  end
  if(pixel_valid && pixel_ready) begin
   bytes_next[count_next*8+:8]=pixel[7:0]; mask_next[count_next]=1;
   if(mode) begin
    bytes_next[(count_next+1)*8+:8]=pixel[15:8]; mask_next[count_next+1]=1;
    bytes_next[(count_next+2)*8+:8]=pixel[23:16]; mask_next[count_next+2]=1;
   end
   count_next=count_next+(mode ? 3 : 1);
  end
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
