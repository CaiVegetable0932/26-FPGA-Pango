`timescale 1ns/1ps
// Purpose: six S(32,26) affine coefficients -> S(24,20) rays, II=1 inside rows.
// Tile start recomputes the exact S(40,26) origin, then adds column increments;
// no rounded delta accumulation. Caller schedules raster or output-tile traversal.
// start_ready waits for all old rays to drain before parameters can change.
module affine_ray_stepper #(parameter TAG_BITS=160)(
 input clk,rst_n,input start_valid,output start_ready,
 input [15:0] start_u,start_v,region_width,region_height,
 input signed [31:0] a00,a01,a02,a10,a11,a12,
 input [TAG_BITS-1:0] region_tag,
 output out_valid,input out_ready,output reg signed [23:0] out_x,out_y,
 // Preserve exact S(40,26) numerators for a following projective divide.
 // Existing affine callers keep the rounded S(24,20) outputs unchanged.
 output reg signed [39:0] out_q0,out_q1,
 output reg [15:0] out_u,out_v,output reg out_ok,out_last,
 output [TAG_BITS-1:0] out_tag,output reg rejected
);
 reg active,result_valid,preparing;
 reg [2:0] prepare_cycle;
 reg [15:0] u,v,left_u,top_v,rw,rh;
 reg signed [63:0] line_x,line_y,acc_x,acc_y;
 reg signed [31:0] dx,dy,rx,ry;
 reg signed [31:0] origin_x,origin_y;
 reg signed [63:0] origin_x_sum,origin_y_sum;
 wire signed [63:0] x_column,x_row,y_column,y_row;
 reg [TAG_BITS-1:0] saved_tag;
 wire advance=!result_valid || out_ready;
 wire signed [63:0] qx=(acc_x+64'sd32)>>>6,qy=(acc_y+64'sd32)>>>6;
 assign start_ready=!active && !result_valid && !preparing,out_valid=result_valid,out_tag=saved_tag;
 // Exact tile-origin calculation is separately pipelined. The small preparation
 // bubble is counted in frame service; never relax a timing constraint to hide it.
 signed_mult32_pipe m_xc(clk,1'b1,dx,$signed({16'd0,left_u}),x_column);
 signed_mult32_pipe m_xr(clk,1'b1,rx,$signed({16'd0,top_v}),x_row);
 signed_mult32_pipe m_yc(clk,1'b1,dy,$signed({16'd0,left_u}),y_column);
 signed_mult32_pipe m_yr(clk,1'b1,ry,$signed({16'd0,top_v}),y_row);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active<=0;result_valid<=0;preparing<=0;prepare_cycle<=0;rejected<=0;end
  else begin
   rejected<=0;
   if(start_valid) begin
    if(start_ready && region_width!=0 && region_height!=0) begin
     preparing<=1;prepare_cycle<=0;u<=start_u;v<=start_v;left_u<=start_u;top_v<=start_v;
     rw<=region_width;rh<=region_height;saved_tag<=region_tag;
     dx<=a00;dy<=a10;rx<=a01;ry<=a11;origin_x<=a02;origin_y<=a12;
    end else rejected<=1;
   end
   if(preparing) begin
    prepare_cycle<=prepare_cycle+1'b1;
    // Bounds validation is a preparation stage, outside the parameter capture
    // enable path. Invalid regions emit no pixels and reopen start_ready.
    if(prepare_cycle==0 && ({1'b0,left_u}+{1'b0,rw}>65536 || {1'b0,top_v}+{1'b0,rh}>65536))begin
     preparing<=0;rejected<=1;
    end
    if(prepare_cycle==3)begin origin_x_sum<=x_column+x_row;origin_y_sum<=y_column+y_row;end
    if(prepare_cycle==4)begin
     line_x<=origin_x_sum+origin_x;line_y<=origin_y_sum+origin_y;
     acc_x<=origin_x_sum+origin_x;acc_y<=origin_y_sum+origin_y;
     preparing<=0;active<=1;
    end
   end
   if(advance) begin
    result_valid<=active;
    if(active) begin
     out_x<=qx[23:0];out_y<=qy[23:0];out_q0<=acc_x[39:0];out_q1<=acc_y[39:0];out_u<=u;out_v<=v;
     out_ok<=acc_x>=-64'sd549755813888 && acc_x<64'sd549755813888 &&
      acc_y>=-64'sd549755813888 && acc_y<64'sd549755813888 &&
      qx>=-64'sd8388608 && qx<64'sd8388608 && qy>=-64'sd8388608 && qy<64'sd8388608;
     out_last<=u==left_u+rw-1 && v==top_v+rh-1;
     if(u==left_u+rw-1) begin
      u<=left_u;v<=v+1'b1;line_x<=line_x+rx;line_y<=line_y+ry;
      acc_x<=line_x+rx;acc_y<=line_y+ry;
      if(v==top_v+rh-1) active<=0;
     end else begin u<=u+1'b1;acc_x<=acc_x+dx;acc_y<=acc_y+dy;end
    end
   end
  end
 end
endmodule
