`timescale 1ns/1ps
// Purpose: own one immutable S1 -> result job across the actual geometry,
// cache refill and coordinate-addressed result writeback. The frame scheduler
// must already hold SRC PROCESS ownership and a freshly allocated DST slot.
// All ports share one processing domain; adapters provide native DMA crossings.
module geometry_frame_processor_external_refill #(parameter META_BITS=616,EXTERNAL_TONE_PAGES=0,HISTORY_SUPPORT=0,PROGRAM_VERSION_SEPARATE=0)(
 input clk,rst_n,input job_valid,output job_ready,
 input [31:0] source_base,source_generation,result_base,result_generation,
 input [15:0] width,height,input [447:0] coefficients,input [META_BITS-1:0] metadata,
 input [1:0] enhancement,input [31:0] lut_version,
 input history_enable,input signed [31:0] history_dx_q16,history_dy_q16,output fill_history,
 output [31:0] current_pixels,history_pixels,invalid_pixels,
 input lut_write,input [7:0] lut_addr,lut_data,input lut_commit,input lut_page,input [31:0] lut_program_version,
 output reg job_done,job_failed,output reg [META_BITS-1:0] result_metadata,
 // Cache-fill stream belongs to processing_clk; native row DMA is external.
 output fill_req_valid,input fill_req_ready,output [11:0] fill_tile_x,fill_tile_y,
 input fill_valid,output fill_ready,input [95:0] fill_rgb,input fill_last,fill_error,
 input [31:0] fill_bus_bytes,input refill_busy,
 output result_req_valid,input result_req_ready,output [31:0] result_req_addr,result_req_tag,
 output [4:0] result_req_beats,output result_cancel,
 output result_w_valid,input result_w_ready,output [255:0] result_w_data,output [31:0] result_w_strb,
 input result_done,output result_done_ready,input result_error,result_cancelled,input [31:0] result_done_tag,
 output [31:0] cache_misses,cache_stalls,output [63:0] cache_bus_bytes
);
 reg active,geometry_finished,writer_finished;
 reg [31:0] held_source_base,held_source_generation;
 reg [15:0] held_width,held_height;
 wire geometry_ready,writer_ready,geometry_done,geometry_failed,geometry_rejected,writer_done,writer_failed;
 wire start=job_valid && job_ready;
 wire out_valid,out_ready,out_mask;wire [23:0] out_rgb;wire [15:0] out_u,out_v;

 wire [31:0] written_pixels;
 assign job_ready=!active && geometry_ready && writer_ready;
 // After a failed writer has drained, continue consuming the geometry pipe
 // into discard so its frame state and any source reads can finish safely.
 assign out_ready=writer_finished || writer_failed || pixel_ready;
 wire pixel_ready;
 geometry_rgb_pipeline #(.FRAME_TAG_BITS(META_BITS),.EXTERNAL_TONE_PAGES(EXTERNAL_TONE_PAGES),.HISTORY_SUPPORT(HISTORY_SUPPORT)) geometry(
  .clk(clk),.rst_n(rst_n),.frame_valid(start),.frame_ready(geometry_ready),
  .frame_width(width),.frame_height(height),.frame_coefficients(coefficients),.frame_tag(metadata),
  .frame_enhancement(enhancement),.frame_lut_version(lut_version),
  .frame_history_enable(history_enable),.frame_history_dx_q16(history_dx_q16),.frame_history_dy_q16(history_dy_q16),
  .fill_history(fill_history),.out_provenance(),.current_pixels(current_pixels),.history_pixels(history_pixels),.invalid_pixels(invalid_pixels),
  // Dual-clock wrappers must program before a job snapshot exists. Keep the
  // programming version independent of the locally captured frame version;
  // the default preserves the original single-clock caller convention.
  .lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),.lut_commit(lut_commit),.lut_version((EXTERNAL_TONE_PAGES || PROGRAM_VERSION_SEPARATE)?lut_program_version:lut_version),.lut_page(lut_page),
  .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_mask(out_mask),.out_u(out_u),.out_v(out_v),
  .fill_req_valid(fill_req_valid),.fill_req_ready(fill_req_ready),.fill_tile_x(fill_tile_x),.fill_tile_y(fill_tile_y),
  .fill_valid(fill_valid),.fill_ready(fill_ready),.fill_rgb(fill_rgb),.fill_last(fill_last),.fill_error(fill_error),
  .fill_bus_bytes(fill_bus_bytes),.frame_done(geometry_done),.frame_failed(geometry_failed),.config_rejected(geometry_rejected),
  .cache_misses(cache_misses),.cache_stalls(cache_stalls),.cache_bus_bytes(cache_bus_bytes));
 // The DDR-domain refill is connected through the bounded quad bridge.
 frame_writer_buffer #(.TILED(1)) writer(.clk(clk),.rst_n(rst_n),.frame_valid(start),.frame_ready(writer_ready),
  .frame_base(result_base),.frame_stride(32'd6144),.frame_generation(result_generation),.frame_width(width),.frame_height(height),
  .frame_rgb888(1'b1),.frame_abort(active && (geometry_failed || geometry_rejected)),
  .in_valid(out_valid && !writer_finished && !writer_failed),.in_ready(pixel_ready),
  .in_pixel(out_mask?out_rgb:24'b0),.in_x(out_u),.in_y(out_v),.frame_done(writer_done),.frame_failed(writer_failed),
  .accepted_pixels(written_pixels),.req_valid(result_req_valid),.req_ready(result_req_ready),.req_addr(result_req_addr),
  .req_tag(result_req_tag),.req_beats(result_req_beats),.w_valid(result_w_valid),.w_ready(result_w_ready),
  .w_data(result_w_data),.w_strb(result_w_strb),.dma_cancel(result_cancel),.done(result_done),.done_ready(result_done_ready),
  .dma_error(result_error),.dma_cancelled(result_cancelled),.done_tag(result_done_tag));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;geometry_finished<=0;writer_finished<=0;job_done<=0;job_failed<=0;result_metadata<=0;
   held_source_base<=0;held_source_generation<=0;held_width<=0;held_height<=0;end
  else begin
   job_done<=0;
   if(start)begin active<=1;geometry_finished<=0;writer_finished<=0;job_failed<=0;result_metadata<=metadata;
    held_source_base<=source_base;held_source_generation<=source_generation;held_width<=width;held_height<=height;end
   if(active)begin
    if(geometry_done)geometry_finished<=1;
    if(writer_done)writer_finished<=1;
    if(geometry_failed || geometry_rejected || writer_failed)job_failed<=1;
    if((geometry_finished || geometry_done) && (writer_finished || writer_done) && !refill_busy)begin
     active<=0;job_done<=1;
     if(written_pixels!=held_width*held_height)job_failed<=1;
    end
   end
  end
 end
endmodule
