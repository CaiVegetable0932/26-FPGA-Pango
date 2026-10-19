`timescale 1ns/1ps
// Purpose: remove the first aligned-beat offset and row tail padding on reads.
// Output is a compact <=32-byte chunk (low byte first); valid_bytes states its
// length. Packet consumers concatenate chunks across rows before segmentation.
// The 64-byte reservoir sustains one input/output beat per cycle with stalls.
module dma_byte_unpack_reference #(parameter ALIGNED_ROWS=0)(
 input clk,input rst_n,input start_valid,output start_ready,
 input [4:0] start_offset,input [31:0] row_bytes,
 input beat_valid,output beat_ready,input [255:0] beat_data,
 output chunk_valid,input chunk_ready,output [255:0] chunk_data,
 output [5:0] valid_bytes,output chunk_last
);
 generate if(ALIGNED_ROWS) begin: aligned_rows
  // Board frame pools guarantee 32-byte aligned row starts. Every beat already
  // is a complete output chunk, so a single elastic register replaces the
  // general 64-byte barrel-shift reservoir. Tail bytes are explicitly zeroed;
  // row_bytes may still be non-multiple-of-32 (small-frame verification).
  reg active,held_valid,held_last;
  reg [31:0] left;
  reg [255:0] held_data;
  reg [5:0] held_bytes;
  wire [5:0] take=left<32 ? left[5:0] : 6'd32;
  assign start_ready=!active && !held_valid;
  assign beat_ready=active && left!=0 && (!held_valid || chunk_ready);
  assign chunk_valid=held_valid,valid_bytes=held_bytes,chunk_last=held_last;
  genvar byte_lane;
  for(byte_lane=0;byte_lane<32;byte_lane=byte_lane+1)begin: trim_tail
   assign chunk_data[byte_lane*8+:8]=byte_lane<held_bytes ? held_data[byte_lane*8+:8] : 8'd0;
  end
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin active<=0;held_valid<=0;held_last<=0;left<=0;held_data<=0;held_bytes<=0;end
   else if(start_valid && start_ready)begin
    active<=row_bytes!=0;left<=row_bytes;held_valid<=0;held_last<=0;
   end else begin
    if(chunk_valid && chunk_ready)begin held_valid<=0;if(held_last)active<=0;end
    if(beat_valid && beat_ready)begin
     held_data<=beat_data;held_bytes<=take;held_last<=left<=32;
     left<=left-take;held_valid<=1;
    end
   end
  end
 end else begin: unaligned_rows
 // General users retain first-beat offset removal and cross-beat concatenation.
 reg active,first;
 reg [4:0] offset;
 reg [31:0] left;
 reg [6:0] count,count_next;
 reg [511:0] bytes_q,bytes_next;
 // These counts never exceed 32/31/32 respectively. Explicit widths prevent
 // the synthesis tool from building full 32-bit shift/mask control paths.
 reg [5:0] take_bytes,out_bytes;
 reg [4:0] skip_bytes;
 assign start_ready=!active;
 assign chunk_valid=active && (count>=32 || (left==0 && count!=0));
 assign chunk_data=bytes_q[255:0];
 assign valid_bytes=(count>=32) ? 6'd32 : count[5:0];
 assign chunk_last=left==0 && count<=32;
 assign beat_ready=active && left!=0 && (count<=32 || (chunk_valid && chunk_ready));
 // Purpose: trim only once at row head, append effective bytes only, and keep
 // buffered output stable under downstream backpressure.
 always @* begin
  bytes_next=bytes_q; count_next=count; skip_bytes=first ? offset : 0;
  take_bytes=(left<(32-skip_bytes)) ? left : (32-skip_bytes);
  out_bytes=(count>=32) ? 32 : count;
  if(chunk_valid && chunk_ready) begin bytes_next=bytes_q>>(out_bytes*8); count_next=count-out_bytes; end
  if(beat_valid && beat_ready) begin
   // Mask off padding so bytes above count cannot pollute a later append.
   bytes_next=bytes_next | (({256'd0,beat_data}>>(skip_bytes*8)) &
     (512'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff>>((64-take_bytes)*8)))<<(count_next*8);
   count_next=count_next+take_bytes;
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active<=0;first<=0;offset<=0;left<=0;count<=0;bytes_q<=0;end
  else if(start_valid && start_ready) begin
   active<=row_bytes!=0; first<=1; offset<=start_offset; left<=row_bytes; count<=0; bytes_q<=0;
  end else begin
   bytes_q<=bytes_next; count<=count_next;
   if(beat_valid && beat_ready) begin left<=left-take_bytes; first<=0; end
   if(chunk_valid && chunk_ready && chunk_last) active<=0;
  end
 end
 end endgenerate
endmodule
