`timescale 1ns/1ps
// Purpose: cycle-exact cache comparison against the pre-optimization source.
// Exercise tag conflicts, cache hits, backpressure, resets and invalidation;
// this is a synthetic miter, not physical DDR timing verification.
module tb_cache_timing_equivalence;
 reg clk=0,rst_n=0,invalidate=0,request=0,response_ready=0;
 reg [27:0] address=0;
 reg read_ready=0,read_valid=0,read_done=0;
 reg [255:0] read_data=0;
 wire cr,gr,cv,gv,cq,gq,cf,gf;
 wire [7:0] cb,gb;wire [27:0] ca,ga;
 wire [31:0] ch,gh,cm,gm;
 integer i,j,seed=32'h63910247,checks=0;
 reg [31:0] random_word;
 always #4 clk=~clk;
 geometry_byte_cache candidate(.clk(clk),.rst_n(rst_n),.invalidate(invalidate),
  .request_valid(request),.request_ready(cr),.address(address),
  .response_valid(cv),.response_ready(response_ready),.value(cb),
  .read_req(cq),.read_addr(ca),.read_ready(read_ready),.read_valid(read_valid),
  .read_done(read_done),.read_data(read_data),.fault(cf),.hits(ch),.misses(cm));
 geometry_byte_cache_golden golden(.clk(clk),.rst_n(rst_n),.invalidate(invalidate),
  .request_valid(request),.request_ready(gr),.address(address),
  .response_valid(gv),.response_ready(response_ready),.value(gb),
  .read_req(gq),.read_addr(ga),.read_ready(read_ready),.read_valid(read_valid),
  .read_done(read_done),.read_data(read_data),.fault(gf),.hits(gh),.misses(gm));
 initial begin
  repeat(3)@(negedge clk);
  for(i=0;i<200000;i=i+1)begin
   // Alternate sustained normal traffic with injected invalidation/fill faults.
   rst_n=(i%2000)!=0;random_word=$random(seed);
   request=random_word[0]|random_word[1];response_ready=random_word[2];
   read_ready=random_word[3];
   read_valid=(candidate.state==3) && !candidate.seen && random_word[4];
   read_done=(candidate.state==3) && (candidate.seen || read_valid) && random_word[5];
   invalidate=(i%2000>1800) && random_word[11:6]==0;
   if(i%128==0)address={$random(seed)} & 28'h01fffff;
   else if(i%8==0)address[4:0]=random_word[16:12];
   for(j=0;j<8;j=j+1)read_data[j*32+:32]=$random(seed);
   @(posedge clk);#1;
   if({cr,cv,cq,ca,cf,ch,cm} !== {gr,gv,gq,ga,gf,gh,gm} || (cv && cb!==gb))
    $fatal(1,"CACHE_TIMING_FAIL cycle=%0d",i);
   checks=checks+1;@(negedge clk);
  end
  $display("CACHE_TIMING_EQUIVALENCE_PASS checks=%0d",checks);$finish;
 end
endmodule
