`timescale 1ns/1ps
module snapshot_tb;
 parameter WIDTH=33,HEIGHT=2;
 reg clk=0;
 reg rst_n=0;
 reg start=0;
 reg cancel=0;
 reg [1:0] source_slot=0;
 reg [1:0] result_slot=0;
 reg [31:0] source_gen=0;
 reg [31:0] result_gen=0;
 reg [31:0] s1_gen=0;
 reg [31:0] dst_gen=0;
 reg req_ready=0;
 reg w_ready=0;
 reg r_valid=0;
 reg [255:0] r_data=0;
 reg dma_done=0;
 reg dma_error=0;
 reg dma_cancelled=0;
 reg [31:0] done_tag=0;
 wire ready;
 wire done;
 wire failed;
 wire drained;
 wire req_valid;
 wire req_write;
 wire [31:0] req_addr;
 wire [31:0] req_tag;
 wire [2:0] req_bank;
 wire [2:0] req_owner;
 wire [1:0] req_slot;
 wire [31:0] req_generation;
 wire w_valid;
 wire [255:0] w_data;
 wire [31:0] w_strb;
 wire r_ready;
 wire dma_done_ready;
 wire dma_cancel;
 wire ref_ready;
 wire ref_done;
 wire ref_failed;
 wire ref_drained;
 wire ref_req_valid;
 wire ref_req_write;
 wire [31:0] ref_req_addr;
 wire [31:0] ref_req_tag;
 wire [2:0] ref_req_bank;
 wire [2:0] ref_req_owner;
 wire [1:0] ref_req_slot;
 wire [31:0] ref_req_generation;
 wire ref_w_valid;
 wire [255:0] ref_w_data;
 wire [31:0] ref_w_strb;
 wire ref_r_ready;
 wire ref_dma_done_ready;
 wire ref_dma_cancel;
snapshot_copy_dma #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) reference_impl(.clk(clk),.rst_n(rst_n),.start(start),.cancel(cancel),.source_slot(source_slot),.result_slot(result_slot),.source_gen(source_gen),.result_gen(result_gen),.s1_gen(s1_gen),.dst_gen(dst_gen),.req_ready(req_ready),.w_ready(w_ready),.r_valid(r_valid),.r_data(r_data),.dma_done(dma_done),.dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag),.ready(ref_ready),.done(ref_done),.failed(ref_failed),.drained(ref_drained),.req_valid(ref_req_valid),.req_write(ref_req_write),.req_addr(ref_req_addr),.req_tag(ref_req_tag),.req_bank(ref_req_bank),.req_owner(ref_req_owner),.req_slot(ref_req_slot),.req_generation(ref_req_generation),.w_valid(ref_w_valid),.w_data(ref_w_data),.w_strb(ref_w_strb),.r_ready(ref_r_ready),.dma_done_ready(ref_dma_done_ready),.dma_cancel(ref_dma_cancel));
snapshot_copy_candidate #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) candidate_impl(.clk(clk),.rst_n(rst_n),.start(start),.cancel(cancel),.source_slot(source_slot),.result_slot(result_slot),.source_gen(source_gen),.result_gen(result_gen),.s1_gen(s1_gen),.dst_gen(dst_gen),.req_ready(req_ready),.w_ready(w_ready),.r_valid(r_valid),.r_data(r_data),.dma_done(dma_done),.dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag),.ready(ready),.done(done),.failed(failed),.drained(drained),.req_valid(req_valid),.req_write(req_write),.req_addr(req_addr),.req_tag(req_tag),.req_bank(req_bank),.req_owner(req_owner),.req_slot(req_slot),.req_generation(req_generation),.w_valid(w_valid),.w_data(w_data),.w_strb(w_strb),.r_ready(r_ready),.dma_done_ready(dma_done_ready),.dma_cancel(dma_cancel));
 integer seed=177,cycle,word_index,checks=0,completed=0;
 always #5 clk=~clk;
 always @(posedge clk)begin #2;
  if(rst_n)begin
   checks=checks+1;
   if({ready,done,failed,drained,req_valid,req_write,req_addr,req_tag,req_bank,req_owner,req_slot,req_generation,w_valid,w_data,w_strb,r_ready,dma_done_ready,dma_cancel} !== {ref_ready,ref_done,ref_failed,ref_drained,ref_req_valid,ref_req_write,ref_req_addr,ref_req_tag,ref_req_bank,ref_req_owner,ref_req_slot,ref_req_generation,ref_w_valid,ref_w_data,ref_w_strb,ref_r_ready,ref_dma_done_ready,ref_dma_cancel})$fatal(1,"SNAPSHOT_CAPTURE_DIFF all public bits");
   if(candidate_impl.local_idle !== {6{ref_ready}})
    $fatal(1,"SNAPSHOT_CAPTURE_DIFF same-edge idle flags");
   if({candidate_impl.ss,candidate_impl.rs,candidate_impl.sg,candidate_impl.rg,candidate_impl.dsg,candidate_impl.drg}
      !== {reference_impl.ss,reference_impl.rs,reference_impl.sg,reference_impl.rg,reference_impl.dsg,reference_impl.drg})
    $fatal(1,"SNAPSHOT_CAPTURE_DIFF inactive metadata");
   if(done)completed=completed+1;
  end
 end
 initial begin
  if($value$plusargs("SEED=%d",seed))begin end
  repeat(3)@(negedge clk);rst_n=1;
  for(cycle=0;cycle<40000;cycle=cycle+1)begin
   @(negedge clk);
   source_slot=$random(seed);result_slot=$random(seed);
   source_gen=$random(seed);result_gen=$random(seed);s1_gen=$random(seed);dst_gen=$random(seed);
   for(word_index=0;word_index<8;word_index=word_index+1)r_data[word_index*32+:32]=$random(seed);
   // First complete real two-image copies under an independent always-ready
   // backend, then inject stalls, early/error ACKs, cancel and cold resets.
   if(cycle<3000)begin
    start=ref_ready;cancel=0;req_ready=1;w_ready=1;r_valid=ref_r_ready;
    dma_done=ref_dma_done_ready;dma_error=0;dma_cancelled=0;done_tag=ref_req_tag;
   end else begin
    start=($random(seed)&3)==0;cancel=($random(seed)&31)==0;
    req_ready=($random(seed)&3)!=0;w_ready=($random(seed)&3)!=0;r_valid=($random(seed)&1)!=0;
    dma_done=ref_dma_done_ready && (($random(seed)&7)==0);
    dma_error=($random(seed)&63)==0;dma_cancelled=($random(seed)&63)==0;
    done_tag=(($random(seed)&15)==0)?$random(seed):ref_req_tag;
    rst_n=(cycle%601)!=0;
   end
  end
  @(negedge clk);rst_n=1;start=0;cancel=0;repeat(3)@(negedge clk);
  if(checks<39000 || completed<1)$fatal(1,"SNAPSHOT_CAPTURE_DIFF insufficient coverage");
  $display("SNAPSHOT_CAPTURE_PASS checks=%0d completions=%0d",checks,completed);$finish;
 end
endmodule
