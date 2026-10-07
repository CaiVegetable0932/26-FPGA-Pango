`timescale 1ns/1ps
// Purpose: independently verify exact signed products, sustained traffic,
// bubbles and reset flushing for every wide operand shape used by geometry.
module mul_case #(parameter A=32,B=36)(output reg done=0);
 reg clk=0,rst=0,valid=0;always #4 clk=~clk;
 reg signed [A-1:0] a;reg signed [B-1:0] b;
 wire out_valid;wire signed [A+B-1:0] product;
 geometry_mul_pipe #(.A_WIDTH(A),.B_WIDTH(B)) dut(clk,rst,valid,a,b,out_valid,product);
 reg signed [A+B-1:0] expected[0:4095];
 integer wr=0,rd=0,i,pass=0,checked=0;
 // Capture the independent full-width multiplication before the DUT launch.
 always @(posedge clk)begin
  if(!rst)begin wr=0;rd=0;end
  else begin
   if(valid)begin expected[wr]=a*b;wr=wr+1;end
   if(out_valid)begin
    if(rd>=wr || product!==expected[rd])
     $fatal(1,"MUL_FAIL A=%0d B=%0d index=%0d got=%h expected=%h",A,B,rd,product,expected[rd]);
    rd=rd+1;checked=checked+1;
   end
  end
 end
 initial begin
  a=0;b=0;repeat(3)@(negedge clk);rst=1;
  for(pass=0;pass<2;pass=pass+1)begin
   for(i=0;i<2048;i=i+1)begin
    @(negedge clk);valid=(i%7!=3);
    a={$random,$random};b={$random,$random};
    // Exercise signed extrema and boundary chunks in addition to random data.
    case(i%32)
     0:begin a={1'b1,{(A-1){1'b0}}};b=-1;end
     1:begin a={1'b1,{(A-1){1'b0}}};b={1'b1,{(B-1){1'b0}}};end
     2:begin a={1'b0,{(A-1){1'b1}}};b={1'b0,{(B-1){1'b1}}};end
     4:begin a=65535;b=65536;end
     5:begin a=-65536;b=-65537;end
     6:begin a=0;b=-1;end
    endcase
   end
   if(pass==0)begin
    // Reset with transactions in flight; old valid tokens must disappear.
    @(negedge clk);rst=0;valid=0;repeat(2)@(negedge clk);rst=1;
   end
  end
  @(negedge clk);valid=0;repeat(12)@(negedge clk);
  if(rd!=wr)$fatal(1,"MUL_FAIL lost results");
  $display("MUL_CASE_PASS A=%0d B=%0d checked=%0d",A,B,checked);done=1;
 end
endmodule
module tb_geometry_mul_pipe;
 wire d0,d1,d2;
 mul_case #(.A(32),.B(36)) m0(d0);
 mul_case #(.A(40),.B(33)) m1(d1);
 mul_case #(.A(32),.B(32)) m2(d2);
 initial begin wait(d0 && d1 && d2);$display("GEOMETRY_MUL_PASS");$finish;end
 initial begin #100000;$fatal(1,"GEOMETRY_MUL_TIMEOUT");end
endmodule
