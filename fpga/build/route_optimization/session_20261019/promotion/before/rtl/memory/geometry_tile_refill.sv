`timescale 1ns/1ps
// Purpose: connect geometry_rgb_pipeline's 32x8 RGB888 cache misses to the
// 256-bit byte-addressed DMA contract. All ports share the processing clock;
// a transaction CDC bridge is required when the native fabric clock differs.
// Read two source rows, emit 16 ordered 2x2 quads, then reuse the row buffers.
// Every native response is drained/ACKed before a row pair becomes readable.
module geometry_tile_refill(
 input clk,rst_n,
 input fill_req_valid,output fill_req_ready,input [11:0] fill_tile_x,fill_tile_y,
 input [31:0] source_base,source_stride,source_generation,
 input [15:0] source_width,source_height,
 output fill_valid,input fill_ready,output [95:0] fill_rgb,
 output fill_last,fill_error,output [31:0] fill_bus_bytes,
 input cancel,
 output req_valid,input req_ready,output [31:0] req_addr,req_tag,
 output [4:0] req_beats,output req_write,output dma_cancel,
 input r_valid,output r_ready,input [255:0] r_data,input r_last,
 input done,output done_ready,input dma_error,dma_cancelled,input [31:0] done_tag,
 output busy
);
 localparam IDLE=0,PREPARE=1,ADDRESS=2,RECEIVE=3,EMIT=4,FAILED=5,VALIDATE=6,SPAN=7;
 reg [2:0] state;
 reg [31:0] base,stride,generation,bus_count,address;
 reg [15:0] width,height,start_y;
 reg [16:0] start_x;
 reg [3:0] row,quad;
 reg [4:0] burst_beats;
 reg [2:0] row_beats,returned,segment_start;
 reg failed,cancelled_seen;
 reg [767:0] row_even,row_odd;
 // Capture, multiply, then validate the entire source span on separate edges.
 // A per-row address recurrence replaces a run-time multiply on every row.
 // Rounding up to a 32-byte boundary stays <=2^32 iff the unrounded end does.
 reg [63:0] span_rows,tile_offset;
 reg [31:0] row_bytes,row_address;
 reg shape_ok;
 wire [16:0] last_row_index={1'b0,height}-17'd1;
 wire [63:0] source_end=span_rows+{32'd0,base}+{32'd0,row_bytes};
 reg [16:0] valid_pixels;
 reg [3:0] needed_beats,page_beats;
 wire response_error=dma_error || dma_cancelled || done_tag!=generation;
 assign fill_req_ready=state==IDLE;
 assign busy=state!=IDLE;
 assign req_valid=state==ADDRESS;
 assign req_addr=address,req_beats=burst_beats,req_tag=generation,req_write=0;
 assign dma_cancel=state==RECEIVE && (cancelled_seen || cancel || failed);
 assign r_ready=state==RECEIVE;
 assign done_ready=state==RECEIVE;
 assign fill_valid=state==EMIT || state==FAILED;
 assign fill_last=state==FAILED || (row==7 && quad==15);
 assign fill_error=state==FAILED;
 assign fill_bus_bytes=bus_count;
 // Memory stores R,G,B in increasing byte addresses. Convert each sample to
 // {R,G,B} and order quad samples even/even, odd/even, even/odd, odd/odd.
 // Edge pixels outside the immutable source frame are virtual zero samples.
 function [23:0] pixel(input [767:0] bytes,input integer x,input integer y);
  integer offset;
  begin offset=x*24;
   if(start_x+x>=width || start_y+y>=height)pixel=0;
   else pixel={bytes[offset+:8],bytes[offset+8+:8],bytes[offset+16+:8]};
  end
 endfunction
 assign fill_rgb=state==FAILED ? 96'b0 : {
  pixel(row_odd,quad*2+1,row),pixel(row_odd,quad*2,row),
  pixel(row_even,quad*2+1,row-1),pixel(row_even,quad*2,row-1)};
 // 32-pixel RGB tiles begin on 32-byte boundaries. Split at both the valid
 // row end and physical 4KiB column boundary; never read stride padding rows.
 always @* begin
  valid_pixels=start_x>=width ? 0 : width-start_x;
  if(valid_pixels>32)valid_pixels=32;
  needed_beats=(valid_pixels*3+31)>>5;
  page_beats=(4096-{1'b0,row_address[11:0]})>>5;
  if(row_address[11:0]<=3584)page_beats=15;
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin
   state<=IDLE;base<=0;stride<=0;generation<=0;bus_count<=0;address<=0;
   width<=0;height<=0;start_x<=0;start_y<=0;row<=0;quad<=0;
   burst_beats<=0;row_beats<=0;returned<=0;segment_start<=0;
   failed<=0;cancelled_seen<=0;row_even<=0;row_odd<=0;
   span_rows<=0;tile_offset<=0;row_bytes<=0;row_address<=0;shape_ok<=0;
  end else begin
   if(cancel && state!=IDLE)cancelled_seen<=1;
   case(state)
    IDLE:if(fill_req_valid)begin
     base<=source_base;stride<=source_stride;generation<=source_generation;
     width<=source_width;height<=source_height;start_x<={fill_tile_x,5'b0};start_y<={fill_tile_y,3'b0};
     row<=0;quad<=0;bus_count<=0;failed<=0;cancelled_seen<=cancel;
     row_even<=0;row_odd<=0;state<=VALIDATE;
    end
    VALIDATE:begin
     // These registers cut metadata -> multiplier -> span-check -> state.
     // No DMA request is visible until all immutable bounds have passed SPAN.
     span_rows<=last_row_index*stride;
     tile_offset<={48'd0,start_y}*{32'd0,stride};row_bytes<=width*32'd3;
     shape_ok<=base[4:0]==0 && stride[4:0]==0 && stride>=width*32'd3 &&
      width>=2 && width<=4096 && height>=2 && height<=4096 && start_x<width && start_y<height;
     state<=SPAN;
    end
    SPAN:begin
     row_address<=base+tile_offset[31:0]+start_x*3;
     if(!shape_ok || source_end>64'h100000000 || cancelled_seen || cancel)state<=FAILED;
     else state<=PREPARE;
    end
    PREPARE:begin
     returned<=0;segment_start<=0;row_beats<=needed_beats;
     if(cancelled_seen || cancel)state<=FAILED;
     else if(start_y+row>=height)begin
      // Missing bottom edge rows contribute virtual zeros, without DDR work.
      if(row[0])begin row_odd<=0;quad<=0;state<=EMIT;end
      else begin row_even<=0;row<=row+1'b1;row_address<=row_address+stride;end
     end else begin
      address<=row_address;burst_beats<=needed_beats<page_beats ? needed_beats : page_beats;
      state<=ADDRESS;
     end
    end
    ADDRESS:if(req_ready)begin state<=RECEIVE;returned<=0;end
    RECEIVE:begin
     if(r_valid)begin
      bus_count<=bus_count+32;returned<=returned+1'b1;
      if(r_last!=(returned==burst_beats-1'b1) || returned>=burst_beats)failed<=1;
      // Up to three aligned beats per row. Masked/virtual tail pixels are
      // excluded when quads are emitted, regardless of DDR padding values.
      if(returned+segment_start<3)begin
       if(row[0])row_odd[(returned+segment_start)*256+:256]<=r_data;
       else row_even[(returned+segment_start)*256+:256]<=r_data;
      end
     end
     if(done)begin
      if(failed || response_error || cancelled_seen || cancel ||
         returned+(r_valid?1:0)!=burst_beats || (r_valid && !r_last))state<=FAILED;
      else if(segment_start+burst_beats<row_beats)begin
       segment_start<=segment_start+burst_beats;address<=address+(burst_beats<<5);
       burst_beats<=row_beats-segment_start-burst_beats;state<=ADDRESS;
      end else if(row[0])begin quad<=0;state<=EMIT;end
      else begin row<=row+1'b1;row_address<=row_address+stride;state<=PREPARE;end
     end
    end
    EMIT:if(fill_ready)begin
     // Never change a stalled output beat even if cancellation arrives.
     if(quad==15 && row==7)state<=IDLE;
     else if(cancelled_seen || cancel)state<=FAILED;
     else if(quad==15)begin
      if(row==7)state<=IDLE;
      else begin row<=row+1'b1;row_address<=row_address+stride;state<=PREPARE;end
     end else quad<=quad+1'b1;
    end
    FAILED:if(fill_ready)state<=IDLE;
    default:state<=FAILED;
   endcase
  end
 end
endmodule
