// Purpose: homogeneous ray (Nx,Ny,Z) -> signed Q26 normalized coordinates.
// Reject rays behind/near the horizon and outside |x|,|y|<=4 BEFORE source
// memory access. Unit Z is exact and fast. Otherwise two parallel restoring
// dividers generate precisely 29 quotient bits; there is no host image warp.
module geometry_ray_normalizer(
 input wire clk,rst_n,start,output wire ready,
 input wire signed [47:0] numerator_x,numerator_y,denominator,
 output reg valid,input wire consume,output reg domain_valid,
 output reg signed [31:0] xq,yq
);
 reg busy,finishing,negative_x,negative_y;reg [5:0] step;
 reg [31:0] divisor,rem_x,rem_y;
 reg [28:0] bits_x,bits_y,quot_x,quot_y;
 wire [47:0] ax=numerator_x[47]?-numerator_x:numerator_x;
 wire [47:0] ay=numerator_y[47]?-numerator_y:numerator_y;
 wire allowed=denominator>=48'sd16384 && denominator<=48'sd2147483647 &&
      ax<=$unsigned(denominator<<<2) && ay<=$unsigned(denominator<<<2);
 wire [32:0] trial_x={rem_x,bits_x[28]},trial_y={rem_y,bits_y[28]};
 assign ready=!busy && !valid;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   busy<=0;finishing<=0;step<=0;valid<=0;domain_valid<=0;xq<=0;yq<=0;
   divisor<=0;rem_x<=0;rem_y<=0;bits_x<=0;bits_y<=0;quot_x<=0;quot_y<=0;
   negative_x<=0;negative_y<=0;
  end else begin
   if(valid && consume)valid<=0;
   if(start && ready)begin
    domain_valid<=allowed;
    if(!allowed)begin xq<=0;yq<=0;valid<=1;end
    else if(denominator==48'sd67108864)begin
     xq<=numerator_x[31:0];yq<=numerator_y[31:0];valid<=1;
    end else begin
     // |N|<=4D implies floor(|N|/8)<D. Only the three low integer
     // bits of N followed by 26 zeros need 29 bounded iterations.
     busy<=1;finishing<=0;step<=0;divisor<=denominator[31:0];
     rem_x<=ax>>3;rem_y<=ay>>3;bits_x<={ax[2:0],26'b0};bits_y<={ay[2:0],26'b0};
     quot_x<=0;quot_y<=0;negative_x<=numerator_x[47];negative_y<=numerator_y[47];
    end
   end
   if(busy && !finishing)begin
    bits_x<=bits_x<<1;bits_y<=bits_y<<1;
    if(trial_x>={1'b0,divisor})begin rem_x<=trial_x-divisor;quot_x<=(quot_x<<1)|1;end
    else begin rem_x<=trial_x;quot_x<=quot_x<<1;end
    if(trial_y>={1'b0,divisor})begin rem_y<=trial_y-divisor;quot_y<=(quot_y<<1)|1;end
    else begin rem_y<=trial_y;quot_y<=quot_y<<1;end
    if(step==28)finishing<=1;else step<=step+1'b1;
   end
   if(busy && finishing)begin
    xq<=negative_x?-$signed({3'b0,quot_x}):$signed({3'b0,quot_x});
    yq<=negative_y?-$signed({3'b0,quot_y}):$signed({3'b0,quot_y});
    valid<=1;busy<=0;finishing<=0;
   end
  end
endmodule
