`timescale 1ns/1ps
// Purpose: full-precision signed 32x32 multiplication with II=1 and three stages.
// Four <=17x17 partial products fit native Logos2 25x18 APM inputs. Splitting
// cross-term reduction and the final carry addition avoids a combinational chain
// of multiple APMs for inferred wide multipliers. No arithmetic truncation.
module signed_mult32_pipe(
 input clk,advance,input signed [31:0] a,b,output reg signed [63:0] product
);
 reg [31:0] ll;
 reg signed [32:0] lh,hl;
 reg signed [31:0] hh;
 reg signed [33:0] cross_term;
 reg signed [63:0] base;
 always @(posedge clk) if(advance) begin
  ll<=a[15:0]*b[15:0];
  lh<=$signed({1'b0,a[15:0]})*$signed(b[31:16]);
  hl<=$signed(a[31:16])*$signed({1'b0,b[15:0]});
  hh<=$signed(a[31:16])*$signed(b[31:16]);
  cross_term<=$signed({lh[32],lh})+$signed({hl[32],hl});
  base<={hh,ll};
  product<=base+($signed({{30{cross_term[33]}},cross_term})<<<16);
 end
endmodule
