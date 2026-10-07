// Purpose: 125 MHz same-input four-state cycle miter, production packed 0F
// versus parallel-valid 69422B. Raw ports/read snapshots are NEVER masked by
// valid/reset. Initial unreset validity X must match, and reset must not clear
// those snapshots. X/Z inactive coordinates are tested; active handshakes,
// selectors and used addresses are binary. This is bounded simulation, not SAT.
`timescale 1ns/1ps
module tb_cache_valid_parallel;
 parameter STRIDE=2048,CACHE_WORDS=1024,N=2048,SEED=20261007;
 localparam SLOT_BITS=$clog2(CACHE_WORDS);
 localparam COMPACT=(STRIDE==2048 && CACHE_WORDS>=256);
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,invalidate=0,request_valid=0,source_valid=1,enhance=0;
 reg [27:0] base=0;reg [11:0] x0=0,x1=0,y0=0,y1=0,frac_x=0,frac_y=0;
 reg window_ready=1,read_ready=0,read_valid=0,read_done=0;
 reg [255:0] read_data=0;
 wire request_ready,window_valid,window_mask,window_enhance,read_req,fault;
 wire [71:0] window_bytes;wire [11:0] window_fx,window_fy;
 wire [27:0] read_addr;wire [4:0] read_len;wire [31:0] hits,misses;
 wire grequest_ready,gwindow_valid,gwindow_mask,gwindow_enhance,gread_req,gfault;
 wire [71:0] gwindow_bytes;wire [11:0] gwindow_fx,gwindow_fy;
 wire [27:0] gread_addr;wire [4:0] gread_len;wire [31:0] ghits,gmisses;
 geometry_window_cache #(.STRIDE(STRIDE),.CACHE_WORDS(CACHE_WORDS)) dut(
  .clk(clk),.rst_n(rst_n),.invalidate(invalidate),.request_valid(request_valid),
  .source_valid(source_valid),.enhance(enhance),.base(base),.x0(x0),.x1(x1),.y0(y0),.y1(y1),
  .frac_x(frac_x),.frac_y(frac_y),.request_ready(request_ready),.window_valid(window_valid),
  .window_ready(window_ready),.window_bytes(window_bytes),.window_mask(window_mask),
  .window_enhance(window_enhance),.window_fx(window_fx),.window_fy(window_fy),
  .read_req(read_req),.read_addr(read_addr),.read_len(read_len),.read_ready(read_ready),
  .read_valid(read_valid),.read_done(read_done),.read_data(read_data),.fault(fault),.hits(hits),.misses(misses));
 geometry_window_cache_golden #(.STRIDE(STRIDE),.CACHE_WORDS(CACHE_WORDS)) golden(
  .clk(clk),.rst_n(rst_n),.invalidate(invalidate),.request_valid(request_valid),
  .source_valid(source_valid),.enhance(enhance),.base(base),.x0(x0),.x1(x1),.y0(y0),.y1(y1),
  .frac_x(frac_x),.frac_y(frac_y),.request_ready(grequest_ready),.window_valid(gwindow_valid),
  .window_ready(window_ready),.window_bytes(gwindow_bytes),.window_mask(gwindow_mask),
  .window_enhance(gwindow_enhance),.window_fx(gwindow_fx),.window_fy(gwindow_fy),
  .read_req(gread_req),.read_addr(gread_addr),.read_len(gread_len),.read_ready(read_ready),
  .read_valid(read_valid),.read_done(read_done),.read_data(read_data),.fault(gfault),.hits(ghits),.misses(gmisses));
 integer cycle=0,accepted=0,emitted=0,reads=0,promotions=0,replays=0,stalls=0;
 integer rejected_slots=0,tag_commits=0,grant_replies=0,fault_mode=0,fault_cases=0;
 integer rng=SEED,drive_rng=SEED^104729,delay_left=0,done_left=0,mstate=0,j;
 integer initial_x_checks=0,valid_checks=0,lookup_checks=0,hold_checks=0,reset_cases=0;
 integer queued_checks=0,fill_checks=0,inactive_xz_cases=0,pre_checks=0,post_checks=0;
 reg [27:0] maddr;reg fast=0,allow_fault=0,block_output=0;
 // Purpose: shared single-beat memory schedules grant/data/done independently,
 // including same-grant replies and four deliberately malformed responses.
 function [7:0] memory_byte(input [27:0] address);
  reg [31:0] mixed;
  begin mixed=(address*32'd73)^(address>>3)^(address>>11)^(address>>18)^(address>>24);memory_byte=mixed[7:0];end
 endfunction
 task load_beat(input [27:0] address);
  begin for(j=0;j<32;j=j+1)read_data[j*8+:8]=memory_byte(address+j);end
 endtask
 always @(negedge clk)begin
  read_valid=0;read_done=0;read_ready=0;
  if(!rst_n)begin mstate=0;window_ready=1;end
  else begin
   window_ready=!block_output && (fast || (cycle%47<31 && $unsigned($random(rng))%4!=0));
   case(mstate)
    1:if(delay_left==0)begin
      load_beat(maddr);read_valid=fault_mode!=1;
      read_done=done_left==0 || fault_mode==1 || fault_mode>=3;
      mstate=read_done?(fault_mode>=3?3:0):2;
     end else delay_left=delay_left-1;
    2:if(done_left==0)begin read_done=1;mstate=0;end
      else begin done_left=done_left-1;if(fault_mode==2)read_valid=1;end
    3:begin read_valid=fault_mode==3;read_done=fault_mode==4;mstate=0;end
   endcase
   if(mstate==0 && !read_valid && !read_done)begin
    read_ready=$unsigned($random(rng))%4!=0;
    if(read_req && read_ready)begin
     maddr=read_addr;delay_left=1+$unsigned($random(rng))%5;
     done_left=fault_mode==2?3:$unsigned($random(rng))%4;mstate=1;
     if(fault_mode==0 && reads%7==0)begin
      load_beat(read_addr);read_valid=1;read_done=1;mstate=0;
     end
    end
   end
  end
 end
 // Purpose: compare every externally visible bit and every common control
 // register, including uninitialized values. Case inequality preserves X/Z.
 task compare_common;
  begin
   if({request_ready,window_valid,window_bytes,window_mask,window_enhance,window_fx,window_fy,
       read_req,read_addr,read_len,fault,hits,misses} !==
      {grequest_ready,gwindow_valid,gwindow_bytes,gwindow_mask,gwindow_enhance,gwindow_fx,gwindow_fy,
       gread_req,gread_addr,gread_len,gfault,ghits,gmisses})
    $fatal(1,"CACHE_VALID_PORT_FAIL cycle=%0d state=%0d golden_state=%0d",cycle,dut.state,golden.state);
   if({dut.state,dut.mask_q,dut.enhance_q,dut.fx_q,dut.fy_q,dut.saved,dut.a_valid,dut.a_stale,
       dut.a_mask,dut.a_enhance,dut.a_fx,dut.a_fy,dut.missing,dut.fill_addr,dut.seen,dut.valids,
       dut.lane_hit,dut.done_seen,dut.fill_applied,dut.response_data_q,dut.response_valid_q,
       dut.response_bytes_valid,dut.response_bytes_q,dut.fill_mask,dut.accept,dut.promote,dut.replay,
       dut.fill_slot,dut.response_phase,dut.fill_write,dut.all_hit,dut.retire,dut.stage_open,dut.first_missing,dut.lookup_bytes} !==
      {golden.state,golden.mask_q,golden.enhance_q,golden.fx_q,golden.fy_q,golden.saved,golden.a_valid,golden.a_stale,
       golden.a_mask,golden.a_enhance,golden.a_fx,golden.a_fy,golden.missing,golden.fill_addr,golden.seen,golden.valids,
       golden.lane_hit,golden.done_seen,golden.fill_applied,golden.response_data_q,golden.response_valid_q,
       golden.response_bytes_valid,golden.response_bytes_q,golden.fill_mask,golden.accept,golden.promote,golden.replay,
       golden.fill_slot,golden.response_phase,golden.fill_write,golden.all_hit,golden.retire,golden.stage_open,golden.first_missing,golden.lookup_bytes})
    $fatal(1,"CACHE_VALID_STATE_FAIL cycle=%0d",cycle);
  end
 endtask
 integer commit_slot;reg commit_now;
 always @(posedge clk)begin
  cycle=cycle+1;compare_common;pre_checks=pre_checks+1;
  commit_now=rst_n && dut.state==4 && dut.done_seen && dut.fill_applied && !fault;
  commit_slot=dut.fill_slot;
  if(rst_n)begin
   if(request_valid && request_ready)accepted=accepted+1;
   if(window_valid && window_ready)emitted=emitted+1;
   if(window_valid && !window_ready)stalls=stalls+1;
   if(read_req && read_ready)begin reads=reads+1;if(read_valid && read_done)grant_replies=grant_replies+1;end
   if(dut.promote)promotions=promotions+1;
   if(dut.replay)replays=replays+1;
   if(dut.a_valid && dut.state!=0)queued_checks=queued_checks+1;
   if(dut.fill_write)fill_checks=fill_checks+1;
  end
  #1;compare_common;post_checks=post_checks+1;
  if(commit_now)begin
   if(dut.valids[commit_slot]!==1'b1)$fatal(1,"CACHE_VALID_TAG_PUBLICATION_FAIL cycle=%0d",cycle);
   tag_commits=tag_commits+1;
  end
  if(rst_n && fault && !allow_fault)$fatal(1,"CACHE_VALID_UNEXPECTED_FAULT cycle=%0d",cycle);
 end
 // Purpose: compare RAW left/right validity at pre-edge AND post-edge for all
 // rows. Independently compute the OLD mux sample and require the new five FFs
 // and selected output to implement that sample at the SAME edge; holds include
 // reset, invalidation, fills and backpressure. RAM/tag reads are unconditional.
 genvar row,col;
 generate for(row=0;row<3;row=row+1)begin: check_rows
  reg expected_left,expected_right,old_left,old_right,enabled;
  reg expected_request_left,expected_request_right,expected_replay_left,expected_replay_right,expected_selector;
  task compare_row;
   begin
    if({dut.rows[row].left_word_q,dut.rows[row].right_word_q,dut.rows[row].left_valid,dut.rows[row].right_valid,
        dut.rows[row].left_address,dut.rows[row].right_address,dut.rows[row].left_slot,dut.rows[row].right_slot,
        dut.rows[row].port_a_addr,dut.rows[row].lookup_enable,dut.rows[row].port_a_enable} !==
       {golden.rows[row].left_word_q,golden.rows[row].right_word_q,golden.rows[row].left_valid,golden.rows[row].right_valid,
        golden.rows[row].left_address,golden.rows[row].right_address,golden.rows[row].left_slot,golden.rows[row].right_slot,
        golden.rows[row].port_a_addr,golden.rows[row].lookup_enable,golden.rows[row].port_a_enable})
     $fatal(1,"CACHE_VALID_ROW_FAIL row=%0d cycle=%0d",row,cycle);
   end
  endtask
  reg wrote;integer write_slot;
  always @(posedge clk)begin
   compare_row;
   enabled=golden.rows[row].lookup_enable;
   old_left=golden.rows[row].left_valid;old_right=golden.rows[row].right_valid;
   expected_left=golden.valids[golden.rows[row].left_slot];
   expected_right=golden.valids[golden.rows[row].right_slot];
   expected_request_left=golden.valids[golden.cache_slot(golden.lanes[row*3].address)];
   expected_request_right=golden.valids[golden.cache_slot(golden.lanes[row*3+2].address)];
   expected_replay_left=golden.valids[golden.cache_slot(golden.a_address[row*3])];
   expected_replay_right=golden.valids[golden.cache_slot(golden.a_address[row*3+2])];
   expected_selector=golden.replay;
   wrote=golden.fill_write;write_slot=golden.rows[row].port_a_addr;
   #1;compare_row;valid_checks=valid_checks+1;
   if(cycle==1)begin
    if({golden.rows[row].left_valid,golden.rows[row].right_valid}!==2'bxx)
     $fatal(1,"CACHE_VALID_INITIAL_X_FAIL row=%0d",row);
    initial_x_checks=initial_x_checks+2;
   end
   if(enabled)begin
    if({dut.rows[row].left_valid,dut.rows[row].right_valid}!=={expected_left,expected_right} ||
       {dut.rows[row].valid_replay_q,dut.rows[row].left_request_valid_q,dut.rows[row].right_request_valid_q,
        dut.rows[row].left_replay_valid_q,dut.rows[row].right_replay_valid_q} !==
       {expected_selector,expected_request_left,expected_request_right,expected_replay_left,expected_replay_right})
     $fatal(1,"CACHE_VALID_SAME_EDGE_FAIL row=%0d cycle=%0d",row,cycle);
    lookup_checks=lookup_checks+1;
   end else begin
    if({dut.rows[row].left_valid,dut.rows[row].right_valid}!=={old_left,old_right})
     $fatal(1,"CACHE_VALID_HOLD_FAIL row=%0d cycle=%0d",row,cycle);
    hold_checks=hold_checks+1;
   end
   if(wrote && dut.rows[row].data[write_slot]!==golden.rows[row].data[write_slot])
    $fatal(1,"CACHE_VALID_RAM_WRITE_FAIL row=%0d cycle=%0d",row,cycle);
   if(commit_now && dut.rows[row].data[commit_slot]!==golden.rows[row].data[commit_slot])
    $fatal(1,"CACHE_VALID_COMMIT_TAG_FAIL row=%0d cycle=%0d",row,cycle);
  end
  for(col=0;col<3;col=col+1)begin: check_columns
   task compare_lane;
    begin
     if({dut.lanes[row*3+col].address,dut.lanes[row*3+col].sx,dut.lanes[row*3+col].sy,
         dut.a_address[row*3+col],dut.address_q[row*3+col],dut.rows[row].columns[col].left_half,
         dut.rows[row].columns[col].right_half,dut.rows[row].columns[col].choose_left,
         dut.rows[row].columns[col].use_left,dut.rows[row].columns[col].chosen_tag,
         dut.rows[row].columns[col].chosen_valid,dut.rows[row].columns[col].chosen_slot_matches,
         dut.rows[row].columns[col].left_byte,dut.rows[row].columns[col].right_byte} !==
        {golden.lanes[row*3+col].address,golden.lanes[row*3+col].sx,golden.lanes[row*3+col].sy,
         golden.a_address[row*3+col],golden.address_q[row*3+col],golden.rows[row].columns[col].left_half,
         golden.rows[row].columns[col].right_half,golden.rows[row].columns[col].choose_left,
         golden.rows[row].columns[col].use_left,golden.rows[row].columns[col].chosen_tag,
         golden.rows[row].columns[col].chosen_valid,golden.rows[row].columns[col].chosen_slot_matches,
         golden.rows[row].columns[col].left_byte,golden.rows[row].columns[col].right_byte})
      $fatal(1,"CACHE_VALID_LANE_FAIL lane=%0d cycle=%0d",row*3+col,cycle);
    end
   endtask
   always @(posedge clk)begin
    compare_lane;
    if(rst_n && COMPACT && dut.promote && dut.a_mask &&
       dut.rows[row].columns[col].chosen_valid &&
       dut.rows[row].columns[col].chosen_tag==dut.cache_tag(dut.a_address[row*3+col]) &&
       !dut.rows[row].columns[col].chosen_slot_matches)rejected_slots=rejected_slots+1;
    #1;compare_lane;
   end
  end
 end endgenerate
 // Purpose: legal requests hold through acceptance. Directed sequences can
 // queue A on B's promotion edge, so fills must stale A and trigger replay.
 task send(input [27:0] b,input [11:0] xa,xb,ya,yb,input valid_source);
  begin
   base=b;x0=xa;x1=xb;y0=ya;y1=yb;source_valid=valid_source;
   enhance=$random(drive_rng);frac_x=$random(drive_rng);frac_y=$random(drive_rng);request_valid=1;
   @(posedge clk);while(!request_ready)@(posedge clk);
   @(negedge clk);request_valid=0;
  end
 endtask
 task drain;
  begin wait(dut.state==0 && !dut.a_valid && !dut.response_valid_q && !dut.response_bytes_valid);repeat(3)@(negedge clk);end
 endtask
 task reset_all;
  begin
   @(negedge clk);rst_n=0;request_valid=0;invalidate=0;
   repeat(4)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);reset_cases=reset_cases+1;
  end
 endtask
 integer i,old_reads;reg [27:0] test_base;reg [11:0] test_x,test_y,test_right;
 initial begin
  reset_all;
  // Purpose: high aliases, unusual third words, hot II=1 windows and random
  // wrapping addresses exercise direct/folded/XOR slots across the full matrix.
  for(i=0;i<16;i=i+1)begin
   old_reads=reads;test_base=28'h20000+(i%2)*(28'd1<<(SLOT_BITS+5));
   send(test_base,31,32,8,9,1);drain;
   if(COMPACT && reads==old_reads)$fatal(1,"CACHE_VALID_HIGH_ALIAS_FAIL");
  end
  send(28'h20000,32,96,8,9,1);drain;send(28'h20000,32,96,8,9,1);drain;
  if(COMPACT && rejected_slots==0)$fatal(1,"CACHE_VALID_WRONG_SLOT_COVERAGE_FAIL");
  send(28'h20000,31,32,8,9,1);drain;old_reads=reads;fast=1;
  for(i=0;i<64;i=i+1)send(28'h20000,31,32,8,9,1);
  drain;fast=0;if(reads!=old_reads)$fatal(1,"CACHE_VALID_HOT_MISS_FAIL");
  for(i=0;i<N;i=i+1)begin
   test_base=$random(drive_rng);test_x=$random(drive_rng);test_y=$random(drive_rng);
   test_right=i%3==0?$random(drive_rng):(test_x==4095?test_x:test_x+12'd1);
   if(i%11==0)test_base=28'hfffffe3;if(i%17==0)test_x=0;
   if(i%19==0)test_y=0;if(i%23==0)test_base=28'h60003;
   send(test_base,test_x,test_right,test_y,i%5==0?12'd4095:test_y+12'd1,i%7!=0);
  end
  drain;
  // Purpose: X/Z inactive coordinates may change stored masked metadata but
  // never enable a lookup. Both raw validity snapshots must hold unchanged.
  send(28'hxxxxxxx,12'hxxx,12'hzzz,12'hzzz,12'hxxx,0);drain;inactive_xz_cases=1;
  base=0;x0=0;x1=0;y0=0;y1=0;source_valid=1;
  old_reads=reads;invalidate=1;@(negedge clk);invalidate=0;
  send(28'h20000,31,32,8,9,1);drain;
  if(reads==old_reads)$fatal(1,"CACHE_VALID_INVALIDATE_MISS_FAIL");
  // Purpose: real reset edges interrupt a pending read and a backpressured
  // completed window. No internal force or reset is added to validity FFs.
  reset_all;send(28'h20000,31,32,8,9,1);wait(read_req);reset_all;
  block_output=1;send(28'h20000,31,32,8,9,1);wait(window_valid);reset_all;block_output=0;
  allow_fault=1;
  for(fault_mode=1;fault_mode<=4;fault_mode=fault_mode+1)begin
   reset_all;send(28'h20000,31,32,8,9,1);wait(fault);repeat(3)@(negedge clk);
   if(request_ready || read_req)$fatal(1,"CACHE_VALID_FAULT_GATE_FAIL");fault_cases=fault_cases+1;
  end
  fault_mode=0;reset_all;send(28'h20000,31,32,8,9,1);wait(read_req);
  @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;
  if(!fault)$fatal(1,"CACHE_VALID_BUSY_INVALIDATE_FAIL");fault_cases=fault_cases+1;
  reset_all;send(28'h20000,31,32,8,9,1);invalidate=1;
  @(negedge clk);invalidate=0;if(!fault)$fatal(1,"CACHE_VALID_QUEUED_INVALIDATE_FAIL");fault_cases=fault_cases+1;
  if(promotions==0 || replays==0 || stalls==0 || grant_replies==0 || tag_commits==0 ||
     queued_checks==0 || fill_checks==0 || initial_x_checks!=6 || lookup_checks==0 || hold_checks==0 || fault_cases!=6)
   $fatal(1,"CACHE_VALID_COVERAGE_FAIL");
  $display("CACHE_VALID_PARALLEL_PASS stride=%0d cache_words=%0d seed=%0d requests=%0d cycles=%0d accepted=%0d emitted=%0d reads=%0d promotions=%0d replays=%0d stalls=%0d wrong_slot_rejects=%0d tag_commits=%0d grant_replies=%0d fault_cases=%0d initial_x_checks=%0d valid_checks=%0d lookup_checks=%0d hold_checks=%0d reset_cases=%0d queued_checks=%0d fill_checks=%0d inactive_xz_cases=%0d pre_checks=%0d post_checks=%0d",STRIDE,CACHE_WORDS,SEED,N,cycle,accepted,emitted,reads,promotions,replays,stalls,rejected_slots,tag_commits,grant_replies,fault_cases,initial_x_checks,valid_checks,lookup_checks,hold_checks,reset_cases,queued_checks,fill_checks,inactive_xz_cases,pre_checks,post_checks);
  $finish;
 end
 initial begin #80000000;$fatal(1,"CACHE_VALID_TIMEOUT cycle=%0d state=%0d fault_mode=%0d",cycle,dut.state,fault_mode);end
endmodule
