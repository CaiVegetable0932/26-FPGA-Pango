`timescale 1ns/1ps
// Purpose: S1 frame/ROI statistics with an atomic last-pixel snapshot.
// Sample every 4x4 relative to ROI, Y=(77R+150G+29B+128)>>8.
// Invalid pixels are excluded; selected-result black borders never affect S1 stats.
module rgb_frame_statistics #(parameter TAG_BITS=192,SUPPORT_ABORT=0)(
 input clk,rst_n,input frame_start,input [TAG_BITS-1:0] frame_tag,
 input frame_abort,output reg result_failed,
 input [15:0] roi_x,roi_y,roi_width,roi_height,
 input pixel_valid,pixel_ready,pixel_mask,pixel_last,
 input [15:0] pixel_x,pixel_y,input [23:0] pixel_rgb,
 output reg result_valid,input result_ready,output reg [TAG_BITS-1:0] result_tag,
 output reg [47:0] luminance_sum,output reg [31:0] samples,dark,saturated,
 output reg [47:0] red_sum,green_sum,blue_sum,output reg [31:0] neutral_count,
 output reg rejected
);
 reg active;
 reg [TAG_BITS-1:0] saved_tag;
 reg [15:0] rx,ry,rw,rh;
 reg [47:0] accum;
 reg [31:0] count,dark_count,sat_count;
 // Neutral-only pre-CCM sums are an optional AWB tap. Exclude dark/clipped
 // channels and strongly chromatic samples rather than assuming gray world.
 reg [47:0] reds,greens,blues;reg [31:0] neutrals;
 wire [7:0] largest=pixel_rgb[23:16]>pixel_rgb[15:8] ?
  (pixel_rgb[23:16]>pixel_rgb[7:0]?pixel_rgb[23:16]:pixel_rgb[7:0]):
  (pixel_rgb[15:8]>pixel_rgb[7:0]?pixel_rgb[15:8]:pixel_rgb[7:0]);
 wire [7:0] smallest=pixel_rgb[23:16]<pixel_rgb[15:8] ?
  (pixel_rgb[23:16]<pixel_rgb[7:0]?pixel_rgb[23:16]:pixel_rgb[7:0]):
  (pixel_rgb[15:8]<pixel_rgb[7:0]?pixel_rgb[15:8]:pixel_rgb[7:0]);
 wire neutral=selected && smallest>=32 && largest<240 && largest-smallest<=(largest>>2);
 // Purpose: keep the constant-weight luma arithmetic in local LUT logic.
 // All products and the rounded sum fit 16 bits (maximum sum is 65408).
 // This changes only native mapping, not pixels, sampling or result latency.
 wire [15:0] weighted_r /* synthesis syn_dspstyle="logic" */ =16'd77*pixel_rgb[23:16];
 wire [15:0] weighted_g /* synthesis syn_dspstyle="logic" */ =16'd150*pixel_rgb[15:8];
 wire [15:0] weighted_b /* synthesis syn_dspstyle="logic" */ =16'd29*pixel_rgb[7:0];
 wire [15:0] luma_sum=weighted_r+weighted_g+weighted_b+16'd128;
 wire [7:0] luma=luma_sum[15:8];
 wire selected=pixel_mask && pixel_x>=rx && pixel_y>=ry &&
  {1'b0,pixel_x} < {1'b0,rx}+{1'b0,rw} && {1'b0,pixel_y} < {1'b0,ry}+{1'b0,rh} &&
  ((pixel_x-rx)&3)==0 && ((pixel_y-ry)&3)==0;
 // Accumulator update and last-pixel publication use one exact next-value
 // expression each. This removes duplicate arithmetic while preserving the
 // final included pixel, stalls, ROI selection and abort snapshots.
 wire [47:0] next_luma=accum+(selected?luma:48'd0);
 wire [31:0] next_count=count+(selected?1'b1:32'd0);
 wire [31:0] next_dark=dark_count+(selected?(luma<32):32'd0);
 wire [31:0] next_saturated=sat_count+(selected?(luma>=250):32'd0);
 wire [47:0] next_red=reds+(neutral?pixel_rgb[23:16]:48'd0);
 wire [47:0] next_green=greens+(neutral?pixel_rgb[15:8]:48'd0);
 wire [47:0] next_blue=blues+(neutral?pixel_rgb[7:0]:48'd0);
 wire [31:0] next_neutral=neutrals+(neutral?1'b1:32'd0);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active<=0;result_valid<=0;result_failed<=0;rejected<=0;accum<=0;count<=0;dark_count<=0;sat_count<=0; end
  else begin
   rejected<=0;
   if(result_valid && result_ready) result_valid<=0;
   if(frame_start) begin
    if(!active && (!result_valid || result_ready) && roi_width!=0 && roi_height!=0) begin
     active<=1;saved_tag<=frame_tag;rx<=roi_x;ry<=roi_y;rw<=roi_width;rh<=roi_height;
     accum<=0;count<=0;dark_count<=0;sat_count<=0;result_failed<=0;reds<=0;greens<=0;blues<=0;neutrals<=0;
    end else rejected<=1;
   end
   if(pixel_valid && pixel_ready && active) begin
    if(neutral)begin reds<=next_red;greens<=next_green;blues<=next_blue;neutrals<=next_neutral;end
    if(selected) begin
     accum<=next_luma;count<=next_count;
     dark_count<=next_dark;sat_count<=next_saturated;
    end
    if(pixel_last) begin
     active<=0;result_valid<=1;result_tag<=saved_tag;
     luminance_sum<=next_luma;samples<=next_count;
     dark<=next_dark;saturated<=next_saturated;
     red_sum<=next_red;green_sum<=next_green;
     blue_sum<=next_blue;neutral_count<=next_neutral;
    end
   end
   // A truncated input may never deliver pixel_last. Finish its statistics
   // explicitly as failed and retain that status alongside the held result.
   if(SUPPORT_ABORT && frame_abort && active)begin
    active<=0;result_valid<=1;result_failed<=1;result_tag<=saved_tag;
    luminance_sum<=accum;samples<=count;dark<=dark_count;saturated<=sat_count;
   end
  end
 end
endmodule
