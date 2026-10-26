`timescale 1ns/1ps
// Purpose: frame-locked affine -> lens -> RGB cache -> enhancement/result pipeline.
// The caller acquires immutable S1
// slot ownership before start and retains it until frame_done AND DMA drains.
// frame_tag is opaque (epoch/frame_id/entity handles can use frame_meta_t width).
// coeff bus: a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy, field0 at LSB.
// Output tag appends output u/v, allowing exact destination addressing and pairing.
module geometry_rgb_pipeline #(parameter FRAME_TAG_BITS=160,parameter SET_BITS=6,parameter TILED=1,
 parameter CACHE_WAY_BITS=1,parameter TILE_X_BITS=5,parameter TILE_Y_BITS=3,parameter EXTERNAL_TONE_PAGES=0,parameter HISTORY_SUPPORT=0)(
 input clk,rst_n,input frame_valid,output frame_ready,
 input [15:0] frame_width,frame_height,input [447:0] frame_coefficients,
 input [FRAME_TAG_BITS-1:0] frame_tag,input [1:0] frame_enhancement,
 input [31:0] frame_lut_version,
 input frame_history_enable,input signed [31:0] frame_history_dx_q16,frame_history_dy_q16,
 output fill_history,output [1:0] out_provenance,
 output reg [31:0] current_pixels,history_pixels,invalid_pixels,
 input lut_write,input [7:0] lut_addr,lut_data,input lut_commit,input [31:0] lut_version,input lut_page,
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
 localparam TAG_BITS=33;
 reg history_enabled;reg signed [31:0] history_dx,history_dy;
 localparam TILE_W=1<<TILE_X_BITS,TILE_H=1<<TILE_Y_BITS;
 reg busy,ending,cache_start;
 reg [15:0] width,height;
 reg [447:0] coefficients;
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
 // Only a legal geometric outside-domain mask may use registered history.
 // Arithmetic/refill faults still fail the frame. Fill is limited to 32 pixels
 // outside the source, and preserves the same current output curve/interpolator.
 wire signed [32:0] history_u=$signed(source_u)-($signed(history_dx)>>>4);
 wire signed [32:0] history_v=$signed(source_v)-($signed(history_dy)>>>4);
 wire history_candidate=HISTORY_SUPPORT && history_enabled && !map_mask && map_ok &&
  history_u>=0 && history_v>=0 && history_u<($signed({1'b0,width})-1)*4096 && history_v<($signed({1'b0,height})-1)*4096 &&
  source_u>=-28'sd131072 && source_v>=-28'sd131072 &&
  source_u<($signed({1'b0,width})+32)*4096 && source_v<($signed({1'b0,height})+32)*4096;
 wire [TAG_BITS-1:0] map_tag;
 wire cache_v,cache_r,cache_mask,cache_fault,cache_reject;
 wire [95:0] samples;wire [11:0] a,b;wire [TAG_BITS-1:0] cache_tag,result_tag;
 wire enhance_reject;
 wire [31:0] hits,duplicates,max_stall;
 wire legal=frame_width>=2 && frame_width<=4096 && frame_height>=2 && frame_height<=4096 &&
  $signed(frame_coefficients[320+:32])>0 && $signed(frame_coefficients[352+:32])>0;
 assign frame_ready=!busy && step_ready && enhance_config_ready && cache_ready && legal;
 assign out_frame_tag=saved_frame_tag,out_u=result_tag[31:16],out_v=result_tag[15:0];
 assign out_provenance=!out_mask?2'd0:result_tag[32]?2'd2:2'd1;
 // Six frame-held affine coefficients produce ideal rays before lens mapping.
 // No depth recurrence or homogeneous divide exists in the active pipeline.
 affine_ray_stepper #(.TAG_BITS(FRAME_TAG_BITS)) u_step(
  .clk(clk),.rst_n(rst_n),.start_valid(region_start),.start_ready(step_ready),.start_u(region_u),.start_v(region_v),
  .region_width(region_w),.region_height(region_h),
  .a00(region_coeff[0+:32]),.a01(region_coeff[32+:32]),.a02(region_coeff[64+:32]),
  .a10(region_coeff[96+:32]),.a11(region_coeff[128+:32]),.a12(region_coeff[160+:32]),.region_tag(saved_frame_tag),
  .out_valid(step_v),.out_ready(step_r),.out_x(ray_x),.out_y(ray_y),.out_u(step_u),.out_v(step_v_coord),
  .out_ok(step_ok),.out_last(step_last),.out_tag(step_tag),.rejected(step_reject));
 lens_inverse_map #(.TAG_BITS(TAG_BITS)) u_map(
  .clk(clk),.rst_n(rst_n),.in_valid(step_v),.in_ready(step_r),.in_x(ray_x),.in_y(ray_y),.in_ok(step_ok),
  .in_tag({1'b0,step_u,step_v_coord}),.k1(coefficients[192+:32]),.k2(coefficients[224+:32]),
  .p1(coefficients[256+:32]),.p2(coefficients[288+:32]),.fx(coefficients[320+:32]),.fy(coefficients[352+:32]),
  .cx(coefficients[384+:32]),.cy(coefficients[416+:32]),.width(width),.height(height),
  .out_valid(map_v),.out_ready(map_r),.out_u(source_u),.out_v(source_v),.out_mask(map_mask),.out_ok(map_ok),.out_tag(map_tag));
 // Purpose: cache tag capacity follows this pipeline's existing <=4096 frame
 // legality. Ceil counts retain edge tiles: actual 32x8 uses X7/Y9, without
 // changing cache sets, queue, data capacity, public requests or accepted clocks.
 // Two ways retain all four parity reads. The selected 128-tile cache
 // reduces tag/memory footprint; miss bandwidth is checked separately.
 rgb_tile_cache #(.WAY_BITS(CACHE_WAY_BITS),.TAG_BITS(TAG_BITS),.SET_BITS(SET_BITS),.TILE_X_BITS(TILE_X_BITS),.TILE_Y_BITS(TILE_Y_BITS),
  .MAX_FRAME_WIDTH(4096),.MAX_FRAME_HEIGHT(4096),.DUAL_SOURCE(HISTORY_SUPPORT)) u_cache(
  .clk(clk),.rst_n(rst_n),.frame_start(cache_start),.frame_ready(cache_ready),.frame_width(width),.frame_height(height),
  .in_valid(map_v),.in_ready(map_r),.in_u(history_candidate?history_u[27:0]:source_u),.in_v(history_candidate?history_v[27:0]:source_v),
  .in_mask(map_mask || history_candidate),.in_tag({history_candidate,map_tag[31:0]}),.in_history(history_candidate),.fill_history(fill_history),
  .out_valid(cache_v),.out_ready(cache_r),.out_samples(samples),.out_a(a),.out_b(b),.out_mask(cache_mask),.out_tag(cache_tag),
  .fill_req_valid(fill_req_valid),.fill_req_ready(fill_req_ready),.fill_tile_x(fill_tile_x),.fill_tile_y(fill_tile_y),
  .fill_valid(fill_valid),.fill_ready(fill_ready),.fill_rgb(fill_rgb),.fill_last(fill_last),.fill_error(fill_error),.fill_bus_bytes(fill_bus_bytes),
  .frame_error(cache_fault),.config_rejected(cache_reject),.hit_pixels(hits),.miss_tiles(cache_misses),.duplicate_samples(duplicates),
  .stall_cycles(cache_stalls),.max_stall_cycles(max_stall),.refill_bus_bytes(cache_bus_bytes),.queue_peak(queue_peak));
 rgb_enhance #(.TAG_BITS(TAG_BITS),.EXTERNAL_PAGES(EXTERNAL_TONE_PAGES)) u_result(
  .clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(enhance_ready),.frame_config_ready(enhance_config_ready),.frame_end(ending && !out_valid && !enhance_ready),
  .frame_mode(frame_enhancement),.frame_lut_version(frame_lut_version),.lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),
  .lut_commit(lut_commit),.lut_version(lut_version),.lut_page(lut_page),.config_rejected(enhance_reject),
  .in_valid(cache_v),.in_ready(cache_r),.in_samples(samples),.in_a(a),.in_b(b),.in_mask(cache_mask),.in_tag(cache_tag),
  .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_mask(out_mask),.out_tag(result_tag),.active_lut_version(active_lut_version));
 // Result completion counts accepted pixels, not elapsed cycles or HDMI refresh.
 // Numerical overflow and refill errors invalidate the ENTIRE frame descriptor.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin busy<=0;ending<=0;cache_start<=0;regions_done<=0;tile_u<=0;tile_v<=0;
   frame_done<=0;frame_failed<=0;config_rejected<=0;outputs<=0;expected<=0;
   history_enabled<=0;history_dx<=0;history_dy<=0;current_pixels<=0;history_pixels<=0;invalid_pixels<=0;end
  else begin
   frame_done<=0;config_rejected<=step_reject || cache_reject || enhance_reject;
   // Delay cache initialization one clock, using already captured dimensions.
   // Rays cannot reach it until origin preparation + lens latency, so no pixel
   // is admitted during initialization. This isolates config legality from the
   // cache READY -> wide arithmetic CE control path without relaxing timing.
   cache_start<=start;
   if(frame_valid && (!legal || busy || (!enhance_config_ready && enhance_ready))) config_rejected<=1;
   if(start) begin
    busy<=1;ending<=0;width<=frame_width;height<=frame_height;coefficients<=frame_coefficients;
    outputs<=0;expected<=frame_width*frame_height;frame_failed<=0;
    saved_frame_tag<=frame_tag;
    history_enabled<=HISTORY_SUPPORT && frame_history_enable;history_dx<=frame_history_dx_q16;history_dy<=frame_history_dy_q16;
    current_pixels<=0;history_pixels<=0;invalid_pixels<=0;
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
   // cache_start is deliberately delayed one edge after frame admission.
   // Until that edge clears the cache's previous frame_error, it belongs to
   // the retired job. No new ray can reach the cache during initialization.
   if(busy && !cache_start && (cache_fault || (map_v && map_r && !map_ok))) frame_failed<=1;
   if(out_valid && out_ready) begin
    if(out_provenance==1)current_pixels<=current_pixels+1;
    else if(out_provenance==2)history_pixels<=history_pixels+1;
    else invalid_pixels<=invalid_pixels+1;
    outputs<=outputs+1'b1;
    if(outputs==expected-1'b1) ending<=1;
   end
   if(ending && enhance_ready && cache_ready && step_ready) begin busy<=0;ending<=0;frame_done<=1;end
  end
 end
endmodule
