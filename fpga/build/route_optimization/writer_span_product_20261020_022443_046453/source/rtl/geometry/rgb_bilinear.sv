`timescale 1ns/1ps
// Purpose: II=1 RGB888 four-neighbour resampling, one final rounding only.
// Global clock enable freezes arithmetic, valid, mask and opaque identity together.
// P00/P10/P01/P11 are packed low to high, each pixel is {R,G,B}.
module rgb_bilinear #(parameter TAG_BITS=192)(
 input clk,rst_n,input in_valid,output in_ready,
 input [95:0] in_samples,input [11:0] in_a,in_b,input in_mask,
 input [TAG_BITS-1:0] in_tag,
 output out_valid,input out_ready,output [23:0] out_rgb,
 output out_mask,output [TAG_BITS-1:0] out_tag
);
 reg [4:0] v,m;
 wire advance=!v[4] || out_ready;
 reg [TAG_BITS-1:0] tags[0:4];
 reg [12:0] wb0,wb1;
 reg [11:0] b0;
 reg [20:0] hp[0:11];
 reg [19:0] top[0:2],bot[0:2];
 reg [32:0] vp[0:5];
 reg [32:0] sum[0:2];
 reg [23:0] result;
 integer c,j;
 assign in_ready=advance;
 assign out_valid=v[4],out_mask=m[4],out_tag=tags[4],out_rgb=result;
 // Widths: 13x8 ->21 (products), horizontal sum20, 13x20 ->33,
 // vertical sum fits32; retain 33 to make additions/rounding explicit.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin v<=0;m<=0;result<=0; end
  else if(advance) begin
   v<={v[3:0],in_valid};m<={m[3:0],in_mask};
   tags[0]<=in_tag;
   for(j=1;j<5;j=j+1) tags[j]<=tags[j-1];
   b0<=in_b;wb0<=13'd4096-{1'b0,b0};wb1<={1'b0,b0};
   for(c=0;c<3;c=c+1) begin
    hp[4*c] <= (13'd4096-{1'b0,in_a})*in_samples[c*8+:8];
    hp[4*c+1] <= {1'b0,in_a}*in_samples[24+c*8+:8];
    hp[4*c+2] <= (13'd4096-{1'b0,in_a})*in_samples[48+c*8+:8];
    hp[4*c+3] <= {1'b0,in_a}*in_samples[72+c*8+:8];
    top[c]<=hp[4*c]+hp[4*c+1];bot[c]<=hp[4*c+2]+hp[4*c+3];
    vp[2*c]<=wb0*top[c];vp[2*c+1]<=wb1*bot[c];
    sum[c]<=vp[2*c]+vp[2*c+1]+33'd8388608;
    result[c*8+:8]<=m[3] ? (sum[c]>>24) : 8'd0;
   end
  end
 end
endmodule
