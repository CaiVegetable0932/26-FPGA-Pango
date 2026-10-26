`timescale 1ns/1ps
// Compare the serial validator to the unchanged combinational arithmetic,
// including products for invalid full-width inputs (not just mostly-false
// legal flags). Live-body changes must revoke old answers immediately.
module tb_affine_reference_pipeline;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0;reg [511:0] entity=0;
 wire reference_legal,legal,valid;
 affine_reference_guard legacy(.entity(entity),.legal(reference_legal));
 affine_reference_guard #(.PIPELINED(1)) dut(.clk(clk),.rst_n(rst_n),.entity(entity),.legal(legal),.result_valid(valid));
 // Check reused arithmetic registers against the exact frozen body while
 // live inputs change, including invalid full-width signed operands.
 affine_reference_guard frozen_oracle(.entity(dut.sequential.frozen),.legal());
 reg signed [63:0] expected_product,expected_residual;
 always @(negedge clk)begin
  case(dut.sequential.product_index)
   0:begin expected_product=frozen_oracle.combinational.sx;expected_residual=frozen_oracle.combinational.ex;end
   1:begin expected_product=frozen_oracle.combinational.sy;expected_residual=frozen_oracle.combinational.ey;end
   2:begin expected_product=frozen_oracle.combinational.ox;expected_residual=frozen_oracle.combinational.tx;end
   3:begin expected_product=frozen_oracle.combinational.oy;expected_residual=frozen_oracle.combinational.ty;end
  endcase
  if(rst_n && dut.sequential.busy)begin
   if(dut.sequential.phase==8 && dut.sequential.current_product!==expected_product)
    $fatal(1,"partial-product mismatch trial=%0d index=%0d",trial,dut.sequential.product_index);
   if(dut.sequential.phase==9 && dut.sequential.current_residual!==expected_residual)
    $fatal(1,"residual mismatch trial=%0d index=%0d",trial,dut.sequential.product_index);
  end
 end
 integer trial,i,cycles,checks=0,seed=32'h1258abcd,shift,boundary;
 reg signed [63:0] focal,centre;
 task verify;
  begin
   cycles=0;
   while(!valid && cycles<73)begin @(negedge clk);cycles=cycles+1;end
   if(!valid)$fatal(1,"reference validation exceeded stable-input bound");
   if(legal!==reference_legal)$fatal(1,"reference legal mismatch trial=%0d",trial);
   checks=checks+1;
  end
 endtask
 task exact_reference;
  begin
   entity=0;shift=20+(trial%10);focal=64'd1<<shift;centre=((trial%41)-20)*65536;
   entity[0+:32]=focal;entity[32+:32]=focal;
   entity[64+:32]=centre;entity[96+:32]=-centre;
   entity[128+:32]=(64'd1<<42)/focal;entity[256+:32]=(64'd1<<42)/focal;
   entity[192+:32]=-(centre<<<26)/focal;entity[288+:32]=(centre<<<26)/focal;
   entity[320+:16]=1920;entity[336+:16]=1080;entity[352+:32]=1;entity[384+:16]=1;
  end
 endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  for(trial=0;trial<512;trial=trial+1)begin
   @(negedge clk);
   if(trial%4==0)exact_reference();
   else begin
    for(i=0;i<16;i=i+1)entity[i*32+:32]=$random(seed);
    // Signed extremes catch low-half sign extension and carry reconstruction.
    if(trial%16==1)begin entity[128+:32]=32'h80000000;entity[0+:32]=32'h80000000;end
    if(trial%16==2)begin entity[192+:32]=32'hffffffff;entity[0+:32]=32'h7fffffff;end
   end
   #1;if(valid)$fatal(1,"stale result remained valid after body change");
   // Change a valid-looking in-flight body before completion. A result may
   // only describe the final exact bytes, regardless of UART pacing.
   if(trial%8==0)begin repeat(7)@(negedge clk);entity[400]=1;end
   verify();
   repeat(2)begin @(negedge clk);if(!valid || legal!==reference_legal)$fatal(1,"cached result unstable");end
  end
  for(i=1;i<=9;i=i+1)begin
   @(negedge clk);entity=~entity;repeat(i)@(negedge clk);rst_n=0;
   @(negedge clk);if(valid || legal)$fatal(1,"reset retained approval");rst_n=1;verify();
  end
  // At maximum legal focal, translation tolerance is exactly +/-2^28.
  // Both inclusive endpoints and one centre unit beyond them must match the
  // original signed64 comparisons for each axis after narrowing the reducer.
  for(boundary=0;boundary<8;boundary=boundary+1)begin
   @(negedge clk);entity=0;
   entity[0+:32]=32'h20000000;entity[32+:32]=32'h20000000;
   entity[128+:32]=8192;entity[256+:32]=8192;
   entity[320+:16]=1920;entity[336+:16]=1080;entity[352+:32]=1;entity[384+:16]=1;
   centre=(boundary%4<2)?4:5;if(boundary%2)centre=-centre;
   if(boundary<4)entity[64+:32]=centre;else entity[96+:32]=centre;
   #1;verify();
   if(legal!==(boundary%4<2))$fatal(1,"inclusive residual boundary mismatch case=%0d",boundary);
  end
  $display("AFFINE_REFERENCE_PIPELINE_PASS checks=%0d residual_boundaries=8",checks-8);$finish;
 end
 initial begin #1000000;$fatal(1,"pipeline test timeout");end
endmodule
