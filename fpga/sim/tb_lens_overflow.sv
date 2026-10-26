`timescale 1ns/1ps
// Purpose: numerical overflow/invalid-lane flags must retain the accepted tag.
// Centre ray remains representable; large rays overflow Horner/radial and never
// yield a valid address. Coordinates are intentionally don't-care when ok=0.
module tb_lens_overflow;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,iv=0,ready=1,in_ok=1;reg signed [23:0] x=0,y=0;
 reg [63:0] tag;wire ir,ov,mask,ok;wire signed [27:0] u,v;wire [63:0] out_tag;
 integer sent,received=0;
 lens_inverse_map #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(ir),.in_x(x),.in_y(y),.in_ok(in_ok),.in_tag(tag),
  .k1(32'sh7c000000),.k2(32'sh7c000000),.p1(32'sh7c000000),.p2(32'sh7c000000),
  .fx(32'sd2097152),.fy(32'sd2097152),.cx(32'sd2097152),.cy(32'sd1572864),.width(16'd64),.height(16'd48),
  .out_valid(ov),.out_ready(ready),.out_u(u),.out_v(v),.out_mask(mask),.out_ok(ok),.out_tag(out_tag));
 always @(negedge clk)ready=$urandom_range(0,4)!=0;
 always @(posedge clk)if(rst_n && ov && ready)begin
  if(out_tag!==received)$fatal(1,"OVERFLOW_FAIL tag alignment");
  if(received==0)begin if(!ok || !mask || u!==131072 || v!==98304)$fatal(1,"OVERFLOW_FAIL valid centre");end
  else if(ok || mask)$fatal(1,"OVERFLOW_FAIL invalid ray became valid");
  received=received+1;
 end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  for(sent=0;sent<3;sent=sent+1)begin
   @(negedge clk);iv=1;tag=sent;in_ok=sent!=2;x=sent==1 ? 24'h700000 : 0;y=x;
   do @(posedge clk);while(!ir);
  end
  @(negedge clk);iv=0;wait(received==3);@(negedge clk);
  $display("OVERFLOW_PASS centre overflow invalid_input tags");$finish;
 end
 initial begin #1000000;$fatal(1,"OVERFLOW_TIMEOUT");end
endmodule
