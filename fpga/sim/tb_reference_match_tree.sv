`timescale 1ns/1ps
// Compare the new kept tree cycle-for-cycle with the frozen pre-fix guard.
// Exercise every input bit, same-cycle cached ABA, seed/upload mux changes,
// in-flight ABA, reset and random bodies without relying on UART spacing.
module tb_reference_match_tree;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,seed_select=1;reg [511:0] seed_body=0,upload_body=0;
 wire [511:0] entity=seed_select?seed_body:upload_body;
 wire actual_valid,actual_legal,old_valid,old_legal;
 affine_reference_guard #(.PIPELINED(1)) tree(.clk(clk),.rst_n(rst_n),.entity(entity),.result_valid(actual_valid),.legal(actual_legal));
 affine_reference_guard_flat #(.PIPELINED(1)) old(.clk(clk),.rst_n(rst_n),.entity(entity),.result_valid(old_valid),.legal(old_legal));
 integer bit_index,cycles,trial,word_index,seed=32'h37981234,observations=0;
 task equal_outputs;
  begin
   if({actual_valid,actual_legal}!=={old_valid,old_legal})$fatal(1,"reference tree output/latency mismatch trial=%0d",trial);
   if(tree.sequential.entity_matches!==(tree.sequential.frozen==entity))$fatal(1,"tree equality differs from original vector equality");
   observations=observations+1;
  end
 endtask
 always @(posedge clk)begin
  #1;equal_outputs();
  if(rst_n && {tree.sequential.phase,tree.sequential.busy,tree.sequential.cached,tree.sequential.frozen}!==
              {old.sequential.phase,old.sequential.busy,old.sequential.cached,old.sequential.frozen})
   $fatal(1,"reference tree changed state schedule");
 end
 task await_valid;
  begin
   #1;cycles=0;
   while(!actual_valid && cycles<73)begin @(negedge clk);cycles=cycles+1;end
   if(!actual_valid)$fatal(1,"tree exceeded existing stable-body bound");
   equal_outputs();
  end
 endtask
 initial begin
  seed_body[0+:32]=32'h04000000;seed_body[32+:32]=32'h04000000;
  seed_body[128+:32]=65536;seed_body[256+:32]=65536;
  seed_body[320+:16]=1920;seed_body[336+:16]=1080;seed_body[352+:32]=1;seed_body[384+:16]=1;
  upload_body=seed_body;
  repeat(3)@(negedge clk);rst_n=1;await_valid();
  if(!actual_legal)$fatal(1,"initial seed was not legal");
  // Return each changed bit before the next active clock. No calculation is
  // allowed to hide a stale cached result, including the padded last leaf.
  seed_select=0;
  for(bit_index=0;bit_index<512;bit_index=bit_index+1)begin
   @(negedge clk);#1;upload_body[bit_index]=~upload_body[bit_index];#1;equal_outputs();
   if(actual_valid!==0 || actual_legal!==0)$fatal(1,"bit %0d did not invalidate immediately",bit_index);
   upload_body[bit_index]=~upload_body[bit_index];#1;equal_outputs();
   if(actual_valid!==1 || actual_legal!==1)$fatal(1,"cached ABA failed bit %0d",bit_index);
  end
  // Four-state reduction must preserve the original == semantics as well.
  @(negedge clk);#1;upload_body[511]=1'bx;#1;equal_outputs();
  upload_body[0]=~upload_body[0];#1;equal_outputs();
  if(actual_valid!==0)$fatal(1,"known mismatch did not dominate unknown bit");
  upload_body=seed_body;
  // Actual seed mux changes: the new body is legal but may not borrow the
  // old body's approval. Switching back while it is busy must also wait.
  @(negedge clk);upload_body[352+:32]=2;#1;equal_outputs();
  if(actual_valid!==0)$fatal(1,"upload replaced seed without invalidation");
  @(negedge clk);seed_select=1;#1;equal_outputs();
  if(actual_valid!==0)$fatal(1,"seed return reused approval for different frozen body");
  @(negedge clk);seed_select=0;await_valid();
  if(!actual_legal)$fatal(1,"in-flight ABA B->A->B did not validate B");
  @(negedge clk);seed_select=1;#1;equal_outputs();
  if(actual_valid!==0)$fatal(1,"seed transition retained upload approval");
  await_valid();
  // A->B->A during A's initial evaluation must retain A's exact completion.
  @(negedge clk);rst_n=0;@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
  seed_select=0;@(negedge clk);seed_select=1;await_valid();
  for(trial=0;trial<64;trial=trial+1)begin
   @(negedge clk);seed_select=0;
   for(word_index=0;word_index<16;word_index=word_index+1)upload_body[word_index*32+:32]=$random(seed);
   if(trial%4==0)begin repeat(3)@(negedge clk);upload_body[trial*7%512]=~upload_body[trial*7%512];end
   await_valid();
  end
  $display("REFERENCE_MATCH_TREE_PASS bit_invalidations=512 cached_ABA=512 random=64 observations=%0d",observations);$finish;
 end
 initial begin #1000000;$fatal(1,"reference match tree timeout");end
endmodule
