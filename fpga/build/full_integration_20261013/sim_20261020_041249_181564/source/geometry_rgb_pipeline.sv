`timescale 1ns/1ps
// Purpose: frame-locked affine -> lens -> RGB cache -> enhancement/result pipeline.
// No top-level/protocol/IP-generator changes. The caller acquires immutable S1
// slot ownership before start and retains it until frame_done AND DMA drains.
// frame_tag is opaque (epoch/frame_id/entity handles can use frame_meta_t width).
// coeff bus: a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy, field0 at LSB.
// Output tag appends output u/v, allowing exact destination addressing and pairing.
module geometry_rgb_pipeline #(parameter FRAME_TAG_BITS=160,parameter SET_BITS=5,parameter TILED=1,
 parameter TILE_X_BITS=5,parameter TILE_Y_BITS=3,parameter PROJECTIVE=0)(
 input clk,rst_n,input frame_valid,output frame_ready,
 input [15:0] frame_width,frame_height,input [447:0] frame_coefficients,
 input [FRAME_TAG_BITS-1:0] frame_tag,input [1:0] frame_enhancement,
 input [95:0] frame_projective,
 input [31:0] frame_lut_version,
 input lut_write,input [7:0] lut_addr,lut_data,input lut_commit,input [31:0] lut_version,
 output out_valid,input out_ready,output [23:0] out_rgb,output out_mask,
 output [15:0] out_u,out_v,output [FRAME_TAG_BITS-1:0] out_frame_tag,
 output fill_req_valid,input fill_req_ready,output [11:0] fill_tile_x,fill_tile_y,
 input fill_valid,output fill_ready,input [95:0] fill_rgb,input fill_last,fill_error,
 input [31:0] fill_bus_bytes,
 output reg frame_done,frame_failed,config_rejected,
 output [31:0] active_lut_version,output [31:0] cache_misses,cache_stalls,
 output [63:0] cache_bus_bytes,output [15:0] queue_peak
);
 // One frame owns the entire drained pipeline. Keep its immutable full metadata
 // in saved_frame_tag; only the per-pixel u/v token needs repeated registers.
 // This preserves every identity bit while reducing ready/CE fanout. A new
 // frame cannot overwrite metadata until all result pixels have retired.
 localparam TAG_BITS=32;
 localparam TILE_W=1<<TILE_X_BITS,TILE_H=1<<TILE_Y_BITS;
 reg busy,ending,cache_start;
 reg [15:0] width,height;
 reg [447:0] coefficients;reg [95:0] projective;
 reg [31:0] outputs,expected;
 reg [15:0] tile_u,tile_v;
 reg [15:0] region_w_reg,region_h_reg,width_m1,height_m1;
 reg regions_done;
 reg [FRAME_TAG_BITS-1:0] saved_frame_tag;
 wire step_ready,enhance_ready,enhance_config_ready,cache_ready;
 wire start=frame_valid && frame_ready;
 // Start ownership/parameter capture first; launch the first region from those
 // registers on the following clock. No ready->wide size mux->APM enable chain.
 wire region_start=busy && !regions_done && step_ready && !ending;
 wire [15:0] region_u=tile_u,region_v=tile_v;
 wire [15:0] region_w=region_w_reg,region_h=region_h_reg;
 wire [447:0] region_coeff=coefficients;
 wire last_column=tile_u[TILE_X_BITS+:16-TILE_X_BITS]==width_m1[TILE_X_BITS+:16-TILE_X_BITS];
 wire last_row=tile_v[TILE_Y_BITS+:16-TILE_Y_BITS]==height_m1[TILE_Y_BITS+:16-TILE_Y_BITS];
 wire step_v,step_r,step_ok,step_last,step_reject;
 wire signed [23:0] ray_x,ray_y;
 wire [15:0] step_u,step_v_coord;
 wire [FRAME_TAG_BITS-1:0] step_tag;
 wire map_v,map_r,map_mask,map_ok;
 wire signed [27:0] source_u,source_v;
 wire [TAG_BITS-1:0] map_tag;
 wire cache_v,cache_r,cache_mask,cache_fault,cache_reject;
 wire [95:0] samples;wire [11:0] a,b;wire [TAG_BITS-1:0] cache_tag,result_tag;
 wire enhance_reject;
 wire [31:0] hits,duplicates,max_stall;
 wire legal=frame_width>=2 && frame_width<=4096 && frame_height>=2 && frame_height<=4096 &&
  $signed(frame_coefficients[320+:32])>0 && $signed(frame_coefficients[352+:32])>0;
 assign frame_ready=!busy && step_ready && enhance_config_ready && cache_ready && legal;
 assign out_frame_tag=saved_frame_tag,out_u=result_tag[31:16],out_v=result_tag[15:0];
 // Frame-held projection coefficients extend the affine inverse map with
 // its third homogeneous row, before lens distortion and the single resample.
 generate if(PROJECTIVE)begin: projective_path
 projective_ray_stepper u_step(.clk(clk),.rst_n(rst_n),.start_valid(region_start),.start_ready(step_ready),
  .start_u(region_u),.start_v(region_v),.region_width(region_w),.region_height(region_h),
  .a00(region_coeff[0+:32]),.a01(region_coeff[32+:32]),.a02(region_coeff[64+:32]),
  .a10(region_coeff[96+:32]),.a11(region_coeff[128+:32]),.a12(region_coeff[160+:32]),
  .a20(projective[0+:32]),.a21(projective[32+:32]),.a22(projective[64+:32]),
  .out_valid(step_v),.out_ready(step_r),.out_x(ray_x),.out_y(ray_y),.out_u(step_u),.out_v(step_v_coord),
  .out_ok(step_ok),.out_last(step_last),.rejected(step_reject));
 end else begin: affine_path
 affine_ray_stepper #(.TAG_BITS(FRAME_TAG_BITS)) u_step(
  .clk(clk),.rst_n(rst_n),.start_valid(region_start),.start_ready(step_ready),.start_u(region_u),.start_v(region_v),
  .region_width(region_w),.region_height(region_h),
  .a00(region_coeff[0+:32]),.a01(region_coeff[32+:32]),.a02(region_coeff[64+:32]),
  .a10(region_coeff[96+:32]),.a11(region_coeff[128+:32]),.a12(region_coeff[160+:32]),.region_tag(saved_frame_tag),
  .out_valid(step_v),.out_ready(step_r),.out_x(ray_x),.out_y(ray_y),.out_u(step_u),.out_v(step_v_coord),
  .out_ok(step_ok),.out_last(step_last),.out_tag(step_tag),.rejected(step_reject));
 end endgenerate
 lens_inverse_map #(.TAG_BITS(TAG_BITS)) u_map(
  .clk(clk),.rst_n(rst_n),.in_valid(step_v),.in_ready(step_r),.in_x(ray_x),.in_y(ray_y),.in_ok(step_ok),
  .in_tag({step_u,step_v_coord}),.k1(coefficients[192+:32]),.k2(coefficients[224+:32]),
  .p1(coefficients[256+:32]),.p2(coefficients[288+:32]),.fx(coefficients[320+:32]),.fy(coefficients[352+:32]),
  .cx(coefficients[384+:32]),.cy(coefficients[416+:32]),.width(width),.height(height),
  .out_valid(map_v),.out_ready(map_r),.out_u(source_u),.out_v(source_v),.out_mask(map_mask),.out_ok(map_ok),.out_tag(map_tag));
 // Purpose: cache tag capacity follows this pipeline's existing <=4096 frame
 // legality. Ceil counts retain edge tiles: actual 32x8 uses X7/Y9, without
 // changing cache sets, queue, data capacity, public requests or accepted clocks.
 rgb_tile_cache #(.TAG_BITS(TAG_BITS),.SET_BITS(SET_BITS),.TILE_X_BITS(TILE_X_BITS),.TILE_Y_BITS(TILE_Y_BITS),
  .MAX_FRAME_WIDTH(4096),.MAX_FRAME_HEIGHT(4096)) u_cache(
  .clk(clk),.rst_n(rst_n),.frame_start(cache_start),.frame_ready(cache_ready),.frame_width(width),.frame_height(height),
  .in_valid(map_v),.in_ready(map_r),.in_u(source_u),.in_v(source_v),.in_mask(map_mask),.in_tag(map_tag),
  .out_valid(cache_v),.out_ready(cache_r),.out_samples(samples),.out_a(a),.out_b(b),.out_mask(cache_mask),.out_tag(cache_tag),
  .fill_req_valid(fill_req_valid),.fill_req_ready(fill_req_ready),.fill_tile_x(fill_tile_x),.fill_tile_y(fill_tile_y),
  .fill_valid(fill_valid),.fill_ready(fill_ready),.fill_rgb(fill_rgb),.fill_last(fill_last),.fill_error(fill_error),.fill_bus_bytes(fill_bus_bytes),
  .frame_error(cache_fault),.config_rejected(cache_reject),.hit_pixels(hits),.miss_tiles(cache_misses),.duplicate_samples(duplicates),
  .stall_cycles(cache_stalls),.max_stall_cycles(max_stall),.refill_bus_bytes(cache_bus_bytes),.queue_peak(queue_peak));
 rgb_enhance #(.TAG_BITS(TAG_BITS)) u_result(
  .clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(enhance_ready),.frame_config_ready(enhance_config_ready),.frame_end(ending && !out_valid && !enhance_ready),
  .frame_mode(frame_enhancement),.frame_lut_version(frame_lut_version),.lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),
  .lut_commit(lut_commit),.lut_version(lut_version),.config_rejected(enhance_reject),
  .in_valid(cache_v),.in_ready(cache_r),.in_samples(samples),.in_a(a),.in_b(b),.in_mask(cache_mask),.in_tag(cache_tag),
  .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_mask(out_mask),.out_tag(result_tag),.active_lut_version(active_lut_version));
 // Result completion counts accepted pixels, not elapsed cycles or HDMI refresh.
 // Numerical overflow and refill errors invalidate the ENTIRE frame descriptor.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin busy<=0;ending<=0;cache_start<=0;regions_done<=0;tile_u<=0;tile_v<=0;
   frame_done<=0;frame_failed<=0;config_rejected<=0;outputs<=0;expected<=0;end
  else begin
   frame_done<=0;config_rejected<=step_reject || cache_reject || enhance_reject;
   // Delay cache initialization one clock, using already captured dimensions.
   // Rays cannot reach it until origin preparation + lens latency, so no pixel
   // is admitted during initialization. This isolates config legality from the
   // cache READY -> wide arithmetic CE control path without relaxing timing.
   cache_start<=start;
   if(frame_valid && (!legal || busy || (!enhance_config_ready && enhance_ready))) config_rejected<=1;
   if(start) begin
    busy<=1;ending<=0;width<=frame_width;height<=frame_height;coefficients<=frame_coefficients;projective<=frame_projective;
    outputs<=0;expected<=frame_width*frame_height;frame_failed<=0;
    saved_frame_tag<=frame_tag;
    tile_u<=0;tile_v<=0;regions_done<=0;width_m1<=frame_width-1'b1;height_m1<=frame_height-1'b1;
    region_w_reg<=TILED && frame_width>TILE_W ? TILE_W : frame_width;
    region_h_reg<=TILED && frame_height>TILE_H ? TILE_H : frame_height;
   end
   // Output tiles improve source locality and recompute exact affine origins.
   // Coordinates in the tag let result DMA restore raster rows; no external
   // pixel format, source identity or frame-pool address convention changes.
   if(region_start) begin
    if(!TILED) regions_done<=1;
    else if(last_column) begin
     tile_u<=0;tile_v<=tile_v+TILE_H;regions_done<=last_row;
     region_w_reg<=width>TILE_W ? TILE_W : width;
     region_h_reg<=((tile_v+TILE_H)>>TILE_Y_BITS)==(height_m1>>TILE_Y_BITS) ?
      {1'b0,height_m1[TILE_Y_BITS-1:0]}+1'b1 : TILE_H;
    end else begin
     tile_u<=tile_u+TILE_W;regions_done<=0;
     region_w_reg<=((tile_u+TILE_W)>>TILE_X_BITS)==(width_m1>>TILE_X_BITS) ?
      {1'b0,width_m1[TILE_X_BITS-1:0]}+1'b1 : TILE_W;
    end
   end
   if(busy && (cache_fault || (map_v && map_r && !map_ok))) frame_failed<=1;
   if(out_valid && out_ready) begin
    outputs<=outputs+1'b1;
    if(outputs==expected-1'b1) ending<=1;
   end
   if(ending && enhance_ready && cache_ready && step_ready) begin busy<=0;ending<=0;frame_done<=1;end
  end
 end
endmodule
