`timescale 1ns/1ps
// Purpose: compare every accepted divider output with the frozen original
// while exercising bubbles, long stalls, pointer wraps and mid-stream reset.
// The runner renames only the original module to perspective_divide_baseline.
module tb_perspective_delay_equivalence;
 reg clk=0,rst_n=0,in_valid=0,out_ready=0,in_ok=0;
 reg signed [39:0] q0=0,q1=0,q2=0;
 reg [31:0] tag=0,seed=32'h51432def;
 wire ar,av,ao,br,bv,bo;
 wire signed [23:0] ax,ay,bx,by;
 wire [31:0] atag,btag;
 integer cycle,checked=0;
 always #4 clk=~clk;
 perspective_divide_baseline #(.TAG_BITS(32)) original(
  clk,rst_n,in_valid,ar,q0,q1,q2,in_ok,tag,av,out_ready,ax,ay,ao,atag);
 perspective_divide #(.TAG_BITS(32)) candidate(
  clk,rst_n,in_valid,br,q0,q1,q2,in_ok,tag,bv,out_ready,bx,by,bo,btag);
 // Compare after nonblocking updates: latency, validity and ready must agree
 // even on bubbles. Payload is authoritative only while out_valid is asserted.
 always @(posedge clk) begin
  #1;
  if({ar,av} !== {br,bv}) $fatal(1,"Handshake mismatch at cycle %0d",cycle);
  if(av) begin
   if({ao,ax,ay,atag} !== {bo,bx,by,btag})
    $fatal(1,"Payload mismatch at cycle %0d",cycle);
   if(out_ready) checked=checked+1;
  end
 end
 initial begin
  for(cycle=0;cycle<20000;cycle=cycle+1) begin
   @(negedge clk);
   rst_n=cycle>5 && !(cycle>=997 && cycle<1004) && !(cycle>=8190 && cycle<8195);
   out_ready=($random(seed)&3)!=0 && !(cycle%257>=120 && cycle%257<180);
   // Retain an unaccepted lane, just as a compliant upstream producer does.
   if(ar || !rst_n) begin
    in_valid=($random(seed)&7)!=0;
    in_ok=($random(seed)&15)!=0;
    q0={$random(seed),$random(seed)};
    q1={$random(seed),$random(seed)};
    q2={$random(seed),$random(seed)};
    tag=$random(seed);
   end
  end
  @(negedge clk);in_valid=0;out_ready=1;
  repeat(40) @(negedge clk);
  if(checked<5000)$fatal(1,"Insufficient compared transactions");
  $display("TB_PERSPECTIVE_DELAY_EQUIVALENCE_PASS checked=%0d",checked);
  $finish;
 end
 initial begin #300000;$fatal(1,"Equivalence timeout");end
endmodule
