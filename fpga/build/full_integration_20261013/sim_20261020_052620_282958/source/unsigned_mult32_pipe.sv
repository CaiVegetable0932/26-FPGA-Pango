`timescale 1ns/1ps
// Exact unsigned 32x32, II=1, three CE-controlled stages. Four 16x16
// partial products fit native Logos2 APMs; cross/final carries are separated.
module unsigned_mult32_pipe(input clk,advance,input [31:0] a,b,output reg [63:0] product);
 reg [31:0] ll,lh,hl,hh;reg [32:0] cross_term;reg [63:0] base;
 always @(posedge clk)if(advance)begin
  ll<=a[15:0]*b[15:0];lh<=a[15:0]*b[31:16];hl<=a[31:16]*b[15:0];hh<=a[31:16]*b[31:16];
  cross_term<={1'b0,lh}+{1'b0,hl};base<={hh,ll};
  product<=base+{15'd0,cross_term,16'd0};
 end
endmodule
