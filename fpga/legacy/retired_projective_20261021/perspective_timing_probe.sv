`timescale 1ns/1ps
// Native synthesis timing probe for the exact divider used by the board.
// Registered abstract I/O exposes internal paths; this is not board routing
// or electrical validation and is never used as the released video top.
module perspective_timing_probe(
 input clk,rst_n,input in_valid,output in_ready,input signed [39:0] q0,q1,q2,
 input [31:0] in_tag,input in_ok,input out_ready,output out_valid,
 output signed [23:0] x,y,output [31:0] out_tag,output out_ok
);
 reg pending,legal;reg signed [39:0] a,b,c;reg [31:0] tag;
 wire ready;
 assign in_ready=!pending || ready;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin pending<=0;legal<=0;a<=0;b<=0;c<=0;tag<=0;end
  else if(in_ready)begin pending<=in_valid;legal<=in_ok;a<=q0;b<=q1;c<=q2;tag<=in_tag;end
 end
 perspective_divide #(.TAG_BITS(32)) divider(.clk(clk),.rst_n(rst_n),.in_valid(pending),.in_ready(ready),
  .q0(a),.q1(b),.q2(c),.in_ok(legal),.in_tag(tag),.out_valid(out_valid),.out_ready(out_ready),.out_x(x),.out_y(y),.out_tag(out_tag),.out_ok(out_ok));
endmodule
