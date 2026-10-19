`timescale 1ns/1ps
// Purpose: optional frame-constant white balance / calibrated S(18,14) CCM.
// Apply to 12-bit linear RGB BEFORE the S1 fixed curve/8-bit quantization.
// Products, row sums and final rounding are separate II=1 stages; no invented
// colour coefficients. Caller must retain the coefficient entity until drained.
module rgb_colour_matrix #(parameter TAG_BITS=192)(
 input clk,rst_n,input in_valid,output in_ready,input [35:0] in_rgb,
 input [161:0] coefficients,input [TAG_BITS-1:0] in_tag,input in_mask,
 output out_valid,input out_ready,output reg [23:0] out_rgb,
 output out_mask,output [TAG_BITS-1:0] out_tag
);
 reg [2:0] v,m;
 reg [TAG_BITS-1:0] tag[0:2];
 reg signed [30:0] product[0:8];
 reg signed [32:0] total[0:2];
 wire advance=!v[2] || out_ready;
 integer i,j;
 function [7:0] quantize(input signed [32:0] value);
  reg signed [33:0] q;
  begin q=($signed(value)+34'sd131072)>>>18;quantize=q<0 ? 0 : q>255 ? 255 : q[7:0];end
 endfunction
 assign in_ready=advance,out_valid=v[2],out_mask=m[2],out_tag=tag[2];
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin v<=0;m<=0;out_rgb<=0;end
  else if(advance) begin
   v<={v[1:0],in_valid};m<={m[1:0],in_mask};tag[0]<=in_tag;tag[1]<=tag[0];tag[2]<=tag[1];
   for(i=0;i<3;i=i+1) begin
    for(j=0;j<3;j=j+1) product[i*3+j]<=$signed(coefficients[(i*3+j)*18+:18])*$signed({1'b0,in_rgb[(2-j)*12+:12]});
    total[i]<=$signed(product[i*3])+$signed(product[i*3+1])+$signed(product[i*3+2]);
    out_rgb[(2-i)*8+:8]<=m[1] ? quantize(total[i]) : 8'd0;
   end
  end
 end
endmodule
