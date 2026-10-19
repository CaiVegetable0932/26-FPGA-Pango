`timescale 1ns/1ps
// Exact signed40 x unsigned B_BITS (40/48), II=1, four CE stages.
// Two A chunks (20 bits) x three B chunks (16/16/rest) use six <=21x17
// native APM products. Partial, row and final carry additions never share
// an APM multiplication edge. No coordinate precision is discarded.
module signed_mult40_unsigned40_pipe #(parameter B_BITS=40)(
 input clk,advance,input signed [39:0] a,input [B_BITS-1:0] b,output reg signed [B_BITS+39:0] product
);
 reg signed [38:0] p00,p01,p02,p10,p11,p12;
 reg signed [55:0] low_pair,high_pair;reg signed [38:0] low_top,high_top;
 localparam ROW_BITS=20+B_BITS+2,PRODUCT_BITS=40+B_BITS;
 reg signed [ROW_BITS-1:0] low_row,high_row;
 always @(posedge clk)if(advance)begin
  p00<=$signed({1'b0,a[19:0]})*$signed({1'b0,b[15:0]});
  p01<=$signed({1'b0,a[19:0]})*$signed({1'b0,b[31:16]});
  p02<=$signed({1'b0,a[19:0]})*$signed({1'b0,b[B_BITS-1:32]});
  p10<=$signed(a[39:20])*$signed({1'b0,b[15:0]});
  p11<=$signed(a[39:20])*$signed({1'b0,b[31:16]});
  p12<=$signed(a[39:20])*$signed({1'b0,b[B_BITS-1:32]});
  low_pair<=$signed({{17{p00[38]}},p00})+($signed({{17{p01[38]}},p01})<<<16);
  high_pair<=$signed({{17{p10[38]}},p10})+($signed({{17{p11[38]}},p11})<<<16);
  low_top<=p02;high_top<=p12;
  low_row<=$signed({{(ROW_BITS-56){low_pair[55]}},low_pair})+($signed({{(ROW_BITS-39){low_top[38]}},low_top})<<<32);
  high_row<=$signed({{(ROW_BITS-56){high_pair[55]}},high_pair})+($signed({{(ROW_BITS-39){high_top[38]}},high_top})<<<32);
  product<=$signed({{(PRODUCT_BITS-ROW_BITS){low_row[ROW_BITS-1]}},low_row})+($signed({{(PRODUCT_BITS-ROW_BITS){high_row[ROW_BITS-1]}},high_row})<<<20);
 end
endmodule
