`timescale 1ns/1ps
// Purpose: convert an elastic raster RAW8/S1 RGB888 or tiled geometry stream
// into real masked native-DMA write transactions. Pixel coordinates determine
// byte addresses; input order is checked, never assumed to be raster for tiles.
// At most 32 pixels/segment; the entire segment is buffered before admission.
// done is the client's drained/verified completion, not raw WLAST.
module frame_pixel_writer #(parameter TILED=0)(
 input clk,rst_n,input frame_valid,output frame_ready,
 input [31:0] frame_base,frame_stride,frame_generation,
 input [15:0] frame_width,frame_height,input frame_rgb888,input frame_abort,
 input in_valid,output in_ready,input [23:0] in_pixel,input [15:0] in_x,in_y,
 output reg frame_done,frame_failed,output reg [31:0] accepted_pixels,
 output req_valid,input req_ready,output req_write,
 output [31:0] req_addr,req_tag,output [4:0] req_beats,
 output w_valid,input w_ready,output [255:0] w_data,output [31:0] w_strb,
 output dma_cancel,input done,output done_ready,input dma_error,dma_cancelled,
 input [31:0] done_tag
);
 localparam [15:0] DIAG_FRAME_WIDTH=16'd1920;
 localparam [15:0] DIAG_FRAME_HEIGHT=16'd1080;
 localparam [31:0] DIAG_FRAME_STRIDE=32'd6144;
 localparam [0:0] DIAG_FRAME_RGB888=1'b1;

 localparam IDLE=0,START_PACK=1,COLLECT=2,REQUEST=3,FEED=4,DRAIN=5,FINISH=6;
 reg [2:0] state;
 reg [31:0] stride,generation,address;
 // Segment addresses follow the same raster/tile coordinate transitions.
 // Keep the active DMA address separate: 4KiB splits may advance it while
 // the next segment address is already prepared. All updates overlap the
 // existing COLLECT/DRAIN work, so the repair adds no segment wait cycles.
 reg [31:0] segment_address,row_base,tile_band_base,tile_top;
 wire [31:0] segment_step=rgb ? 32'd96 : 32'd32;
 wire [31:0] next_band_base=tile_band_base+(stride<<3);
 reg [15:0] width,height,x,y,tile_x,tile_y;
 reg rgb,last_segment,aborting;
 reg [2:0] stored,feed_index;
 reg [4:0] burst_beats,remaining_beats;
 reg [2:0] burst_start;
 // Store each complete data/mask beat together in dedicated RAM.
 // Storage remains unreset; control prevents use before segment collection.
 reg [287:0] segment_cache[0:2] /* synthesis syn_ramstyle="block_ram,low_power" */;
 reg [287:0] segment_read;
 wire segment_end=(x[4:0]==31 || x==width-1'b1);
 wire final_pixel=x==width-1'b1 && y==height-1'b1;
 wire pack_start_ready,pack_pixel_ready,pack_valid,pack_last;
 wire [255:0] pack_data;wire [31:0] pack_strb;
 wire correct_pixel=in_x==x && in_y==y;
 wire [63:0] span_end={32'd0,frame_base}+({48'd0,DIAG_FRAME_HEIGHT}-1)*{32'd0,DIAG_FRAME_STRIDE}+
  {48'd0,DIAG_FRAME_WIDTH}*(DIAG_FRAME_RGB888 ? 64'd3 : 64'd1);
 assign frame_ready=state==IDLE;
 assign in_ready=state==COLLECT && pack_pixel_ready && !aborting && !frame_abort;
 assign req_valid=state==REQUEST,req_write=1,req_addr=address,req_tag=generation,req_beats=burst_beats;
 assign w_valid=state==FEED && feed_index<burst_beats && !aborting && !frame_abort;
 assign w_data=segment_read[287:32],w_strb=segment_read[31:0];
 assign dma_cancel=(state==FEED || state==DRAIN) && (aborting || frame_abort);
 assign done_ready=state==FEED || state==DRAIN;
 // The packer is private local state; abort may clear it before a DDR request
 // is issued. It never resets the DMA/controller or any shared CDC FIFO.
 dma_pixel_pack pack(.clk(clk),.rst_n(rst_n && !aborting),
  .start_valid(state==START_PACK),.start_ready(pack_start_ready),.start_offset(5'b0),.rgb888(rgb),
  .pixel_valid(in_valid && in_ready),.pixel_ready(pack_pixel_ready),
  .pixel(rgb ? {in_pixel[7:0],in_pixel[15:8],in_pixel[23:16]} : in_pixel),.pixel_last(segment_end),
  .beat_valid(pack_valid),.beat_ready(state==COLLECT),.beat_data(pack_data),.beat_strb(pack_strb),.beat_last(pack_last));

 // REQUEST already precedes FEED, providing the first synchronous read.
 // On an accepted beat prefetch the next index at the same edge that advances
 // feed_index. Backpressure rereads the held beat; a split starts a new REQUEST.
 // No new state or ready/valid latency is introduced. Out-of-range data is
 // irrelevant after the final beat because the original w_valid deasserts.
 // A split REQUEST retains the prior feed_index until req_ready, so its
 // first read must explicitly select burst_start rather than that old index.
 wire [2:0] segment_read_index=(state==REQUEST) ? burst_start :
  burst_start+feed_index+((state==FEED && w_valid && w_ready) ? 3'd1 : 3'd0);
 always @(posedge clk)begin
  segment_read<=segment_cache[segment_read_index];
  if(rst_n && state==COLLECT && !aborting && !frame_abort && pack_valid && stored<3)
   segment_cache[stored]<={pack_data,pack_strb};
 end

 // Coordinates advance by raster or 32x8 tile rows. A tile may be partial on
 // either edge; exact position checking catches duplicate or missing pixels.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;segment_address<=0;row_base<=0;tile_band_base<=0;tile_top<=0;stride<=0;generation<=0;address<=0;width<=0;height<=0;
   x<=0;y<=0;tile_x<=0;tile_y<=0;rgb<=0;last_segment<=0;aborting<=0;
   stored<=0;feed_index<=0;burst_beats<=0;remaining_beats<=0;burst_start<=0;
   frame_done<=0;frame_failed<=0;accepted_pixels<=0;
  end else begin
   frame_done<=0;
   if(frame_abort && state!=IDLE)begin aborting<=1;frame_failed<=1;end
   case(state)
    IDLE:if(frame_valid)begin
     segment_address<=frame_base;row_base<=frame_base;tile_band_base<=frame_base;tile_top<=frame_base;stride<=DIAG_FRAME_STRIDE;generation<=frame_generation;rgb<=DIAG_FRAME_RGB888;
     width<=DIAG_FRAME_WIDTH;height<=DIAG_FRAME_HEIGHT;x<=0;y<=0;tile_x<=0;tile_y<=0;
     aborting<=0;frame_failed<=0;accepted_pixels<=0;last_segment<=0;state<=START_PACK;
     if(DIAG_FRAME_WIDTH==0 || DIAG_FRAME_HEIGHT==0 || DIAG_FRAME_WIDTH>4096 || DIAG_FRAME_HEIGHT>4096 ||
        frame_base[4:0]!=0 || DIAG_FRAME_STRIDE[4:0]!=0 ||
        DIAG_FRAME_STRIDE<DIAG_FRAME_WIDTH*(DIAG_FRAME_RGB888 ? 3:1) ||
        ((span_end+31)&64'hffffffffffffffe0)>64'h100000000)begin frame_failed<=1;state<=FINISH;end
    end
    START_PACK:begin
     stored<=0;burst_start<=0;feed_index<=0;
     address<=segment_address;
     if(aborting || frame_abort)state<=FINISH;
     else if(pack_start_ready)state<=COLLECT;
    end
    COLLECT:begin
     if(aborting || frame_abort)state<=FINISH;
     else begin
      if(in_valid && in_ready)begin
       accepted_pixels<=accepted_pixels+1'b1;
       if(!correct_pixel)begin frame_failed<=1;aborting<=1;state<=FINISH;end
       last_segment<=final_pixel;
       if(segment_end)begin
        if(!TILED)begin
         x<=(x==width-1'b1) ? 0 : x+1'b1;
         if(x==width-1'b1)begin
          y<=y+1'b1;row_base<=row_base+stride;segment_address<=row_base+stride;
         end else segment_address<=segment_address+segment_step;
        end
        else begin
         x<=tile_x;
         if(y==height-1'b1 || y[2:0]==7)begin
          if(tile_x+32>=width)begin
           tile_x<=0;x<=0;tile_y<=tile_y+8;y<=tile_y+8;
           tile_band_base<=next_band_base;tile_top<=next_band_base;segment_address<=next_band_base;
          end
          else begin
           tile_x<=tile_x+32;x<=tile_x+32;y<=tile_y;
           tile_top<=tile_top+segment_step;segment_address<=tile_top+segment_step;
          end
         end else begin y<=y+1'b1;segment_address<=segment_address+stride;end
        end
       end else x<=x+1'b1;
      end
      if(pack_valid)begin
       if(stored>=3)begin frame_failed<=1;state<=FINISH;end
       else begin
        stored<=stored+1'b1;
        if(pack_last)begin
         remaining_beats<=stored+1'b1;
         // A 96-byte tile segment can straddle a 4KiB native column boundary.
         burst_beats<=(4096-{1'b0,address[11:0]})/32<stored+1 ?
          (4096-{1'b0,address[11:0]})/32 : stored+1;
         state<=REQUEST;
        end
       end
      end
     end
    end
    REQUEST:if(req_ready)begin feed_index<=0;state<=FEED;end
    FEED:begin
     if(w_valid && w_ready)begin feed_index<=feed_index+1'b1;if(feed_index==burst_beats-1)state<=DRAIN;end
     if(done)begin
      frame_failed<=1;state<=FINISH;
     end
    end
    DRAIN:if(done)begin
     if(dma_error || dma_cancelled || done_tag!=generation || aborting || frame_abort)begin
      frame_failed<=1;state<=FINISH;
     end else if(remaining_beats>burst_beats)begin
      address<=address+(burst_beats<<5);burst_start<=burst_start+burst_beats;
      remaining_beats<=remaining_beats-burst_beats;burst_beats<=remaining_beats-burst_beats;
      state<=REQUEST;
     end else state<=last_segment?FINISH:START_PACK;
    end
    FINISH:begin frame_done<=1;state<=IDLE;end
    default:begin frame_failed<=1;state<=FINISH;end
   endcase
  end
 end
endmodule
