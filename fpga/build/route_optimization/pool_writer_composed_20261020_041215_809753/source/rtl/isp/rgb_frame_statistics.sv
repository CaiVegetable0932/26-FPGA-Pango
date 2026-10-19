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
 output reg rejected
);
 reg active;
 reg [TAG_BITS-1:0] saved_tag;
 reg [15:0] rx,ry,rw,rh;
 reg [47:0] accum;
 reg [31:0] count,dark_count,sat_count;
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
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active<=0;result_valid<=0;result_failed<=0;rejected<=0;accum<=0;count<=0;dark_count<=0;sat_count<=0; end
  else begin
   rejected<=0;
   if(result_valid && result_ready) result_valid<=0;
   if(frame_start) begin
    if(!active && (!result_valid || result_ready) && roi_width!=0 && roi_height!=0) begin
     active<=1;saved_tag<=frame_tag;rx<=roi_x;ry<=roi_y;rw<=roi_width;rh<=roi_height;
     accum<=0;count<=0;dark_count<=0;sat_count<=0;result_failed<=0;
    end else rejected<=1;
   end
   if(pixel_valid && pixel_ready && active) begin
    if(selected) begin
     accum<=accum+luma;count<=count+1'b1;
     dark_count<=dark_count+(luma<32);sat_count<=sat_count+(luma>=250);
    end
    if(pixel_last) begin
     active<=0;result_valid<=1;result_tag<=saved_tag;
     luminance_sum<=accum+(selected ? luma : 0);samples<=count+selected;
     dark<=dark_count+(selected && luma<32);saturated<=sat_count+(selected && luma>=250);
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
