`timescale 1ns/1ps
// Purpose: exact tiled 3x3 projective numerator/depth recurrences followed by
// the optimized II=1 perspective divider. Positive/near-zero depth and numeric
// failures propagate as invalid rays; mechanical yaw is never treated as roll.
module projective_ray_stepper(
 input clk,rst_n,input start_valid,output start_ready,
 input [15:0] start_u,start_v,region_width,region_height,
 input signed [31:0] a00,a01,a02,a10,a11,a12,a20,a21,a22,
 output out_valid,input out_ready,output signed [23:0] out_x,out_y,
 output [15:0] out_u,out_v,output out_ok,out_last,output rejected
);
 wire xy_valid,z_valid,xy_ready,z_ready,xy_ok,z_ok,xy_rejected,z_rejected,divide_ready;
 wire signed [39:0] q0,q1,q2;wire [15:0] xy_u,xy_v,z_u,z_v;
 wire pair_valid=xy_valid && z_valid;
 wire pair_ready=divide_ready && pair_valid;
 reg [16:0] outstanding;reg [15:0] last_u,last_v;
 wire [31:0] coordinates;
 assign start_ready=xy_ready && z_ready && outstanding==0 && !out_valid;
 assign out_u=coordinates[31:16],out_v=coordinates[15:0];
 assign out_last=out_u==last_u && out_v==last_v;
 assign rejected=xy_rejected || z_rejected;
 // Both recurrences have the same preparation/elastic stages. Mutual ready
 // keeps their coordinates paired even if the divider or cache backpressures.
 affine_ray_stepper #(.TAG_BITS(1)) xy(.clk(clk),.rst_n(rst_n),.start_valid(start_valid && start_ready),.start_ready(xy_ready),
  .start_u(start_u),.start_v(start_v),.region_width(region_width),.region_height(region_height),
  .a00(a00),.a01(a01),.a02(a02),.a10(a10),.a11(a11),.a12(a12),.region_tag(1'b0),
  .out_valid(xy_valid),.out_ready(pair_ready),.out_x(),.out_y(),.out_q0(q0),.out_q1(q1),
  .out_u(xy_u),.out_v(xy_v),.out_ok(xy_ok),.out_last(),.out_tag(),.rejected(xy_rejected));
 affine_ray_stepper #(.TAG_BITS(1)) depth(.clk(clk),.rst_n(rst_n),.start_valid(start_valid && start_ready),.start_ready(z_ready),
  .start_u(start_u),.start_v(start_v),.region_width(region_width),.region_height(region_height),
  .a00(a20),.a01(a21),.a02(a22),.a10(32'sd0),.a11(32'sd0),.a12(32'sd0),.region_tag(1'b0),
  .out_valid(z_valid),.out_ready(pair_ready),.out_x(),.out_y(),.out_q0(q2),.out_q1(),
  .out_u(z_u),.out_v(z_v),.out_ok(z_ok),.out_last(),.out_tag(),.rejected(z_rejected));
 perspective_divide #(.TAG_BITS(32)) divide(.clk(clk),.rst_n(rst_n),.in_valid(pair_valid),.in_ready(divide_ready),
  .q0(q0),.q1(q1),.q2(q2),.in_ok(xy_ok && z_ok && xy_u==z_u && xy_v==z_v),.in_tag({xy_u,xy_v}),
  .out_valid(out_valid),.out_ready(out_ready),.out_x(out_x),.out_y(out_y),.out_ok(out_ok),.out_tag(coordinates));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin outstanding<=0;last_u<=0;last_v<=0;end
  else begin
   if(start_valid && start_ready)begin last_u<=start_u+region_width-1'b1;last_v<=start_v+region_height-1'b1;end
   case({pair_valid && divide_ready,out_valid && out_ready})
    2'b10:outstanding<=outstanding+1'b1;
    2'b01:outstanding<=outstanding-1'b1;
   endcase
  end
 end
endmodule
