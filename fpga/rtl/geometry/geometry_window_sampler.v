// Purpose: frame-scoped parallel RAW footprint cache and exact gray pipeline.
// Invalidate only after every result has been consumed. Source-invalid requests
// produce a black, invalid-mask result and never start a memory transaction.
// CACHE_WORDS=64 retains the prior small-cache implementation for comparison;
// 256 retains four complete rows; default 1024 retains sixteen stride-2048
// rows, selected by exact full-frame fisheye locality replay. Physical DRM
// packing and clock timing require a fresh native synthesis/STA check.
module geometry_window_sampler #(parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048,CACHE_WORDS=1024)(
 input wire clk,rst_n,invalidate,request_valid,source_valid,enhance,
 input wire [27:0] base,input wire [11:0] x0,x1,y0,y1,frac_x,frac_y,
 output wire request_ready,result_valid,output wire [7:0] pixel,
 output wire mask_valid,input wire result_ready,
 output wire read_req,output wire [27:0] read_addr,output wire [4:0] read_len,
 input wire read_ready,read_valid,read_done,input wire [255:0] read_data,
 output wire fault,output wire [31:0] hits,misses
);
 wire window_valid,window_ready,window_mask,window_enhance,pipe_busy;
 wire [71:0] window_bytes;wire [11:0] window_fx,window_fy;
 wire cache_fault,cache_ready;reg invalidate_fault;
 assign fault=cache_fault || invalidate_fault;
 assign request_ready=cache_ready && !invalidate_fault;
 // Purpose: a frame boundary may clear cache metadata only after arithmetic
 // drains; a violated boundary is sticky and blocks future input requests.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)invalidate_fault<=0;
  else if(invalidate && pipe_busy)invalidate_fault<=1;
 geometry_window_cache #(.STRIDE(STRIDE),.CACHE_WORDS(CACHE_WORDS)) u_window(
  .clk(clk),.rst_n(rst_n),.invalidate(invalidate),
  .request_valid(request_valid && !invalidate_fault),.request_ready(cache_ready),
  .source_valid(source_valid),.enhance(enhance),.base(base),
  .x0(x0),.x1(x1),.y0(y0),.y1(y1),.frac_x(frac_x),.frac_y(frac_y),
  .window_valid(window_valid),.window_ready(window_ready),.window_bytes(window_bytes),
  .window_mask(window_mask),.window_enhance(window_enhance),
  .window_fx(window_fx),.window_fy(window_fy),
  .read_req(read_req),.read_addr(read_addr),.read_len(read_len),
  .read_ready(read_ready),.read_valid(read_valid),.read_done(read_done),.read_data(read_data),
  .fault(cache_fault),.hits(hits),.misses(misses));
 geometry_gray_stream u_gray(.clk(clk),.rst_n(rst_n),
  .request_valid(window_valid),.request_ready(window_ready),.samples(window_bytes),
  .source_valid(window_mask),.enhance(window_enhance),.frac_x(window_fx),.frac_y(window_fy),
  .result_valid(result_valid),.result_ready(result_ready),.pixel(pixel),.mask_valid(mask_valid),.busy(pipe_busy));
endmodule
