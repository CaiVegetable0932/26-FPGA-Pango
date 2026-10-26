`timescale 1ns/1ps
// Purpose: check exact lens coordinates, masks, tags and handshake against the
// frozen original under stalls, bubbles, circular address wrap and warm reset.
module tb_lens_delay_equivalence;
 reg clk=0,rst_n=0,in_valid=0,out_ready=0,in_ok=0;
 reg signed [23:0] x=0,y=0;
 reg signed [31:0] k1=-3355443,k2=671089,p1=67109,p2=-33554;
 reg [31:0] tag=0,seed=32'h31432def;
 wire ar,av,am,ao,br,bv,bm,bo;
 wire signed [27:0] au,aw,bu,bw;
 wire [31:0] atag,btag;
 integer cycle,checked=0;
 always #4 clk=~clk;
 lens_inverse_map_baseline #(.TAG_BITS(32)) original(
  clk,rst_n,in_valid,ar,x,y,in_ok,tag,k1,k2,p1,p2,
  32'sd65536000,32'sd65536000,32'sd62914560,32'sd35389440,
  16'd1920,16'd1080,av,out_ready,au,aw,am,ao,atag);
 lens_inverse_map #(.TAG_BITS(32)) candidate(
  clk,rst_n,in_valid,br,x,y,in_ok,tag,k1,k2,p1,p2,
  32'sd65536000,32'sd65536000,32'sd62914560,32'sd35389440,
  16'd1920,16'd1080,bv,out_ready,bu,bw,bm,bo,btag);
 // Invalid arithmetic lanes are still compared whenever out_valid is set:
 // retaining the original rejection flag must not hide latency/tag drift.
 always @(posedge clk) begin
  #1;
  if({ar,av} !== {br,bv})$fatal(1,"Lens handshake mismatch cycle=%0d",cycle);
  if(av)begin
   if({am,ao,au,aw,atag} !== {bm,bo,bu,bw,btag})
    $fatal(1,"Lens payload mismatch cycle=%0d",cycle);
   if(out_ready)checked=checked+1;
  end
 end
 initial begin
  for(cycle=0;cycle<20000;cycle=cycle+1)begin
   @(negedge clk);
   rst_n=cycle>5 && !(cycle>=997 && cycle<1004) && !(cycle>=8190 && cycle<8195);
   out_ready=($random(seed)&3)!=0 && !(cycle%257>=120 && cycle%257<180);
   if(ar || !rst_n)begin
    in_valid=($random(seed)&7)!=0;in_ok=($random(seed)&15)!=0;
    x=$random(seed);y=$random(seed);tag=$random(seed);
   end
  end
  @(negedge clk);in_valid=0;out_ready=1;
  repeat(40)@(negedge clk);
  if(checked<5000)$fatal(1,"Insufficient lens transactions");
  $display("TB_LENS_DELAY_EQUIVALENCE_PASS checked=%0d",checked);$finish;
 end
 initial begin #300000;$fatal(1,"Lens equivalence timeout");end
endmodule
