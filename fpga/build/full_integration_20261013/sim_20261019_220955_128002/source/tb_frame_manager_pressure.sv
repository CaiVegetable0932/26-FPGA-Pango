`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: independent slot/transaction scoreboard drives overlapping operation
// lanes with seeded stalls. Model phases track externally accepted events only;
// source frame identity order and transaction conservation are checked at use.
module tb_frame_manager_pressure;
 reg clk=0,reset_n=0,fabric_ready=0;
 frame_cmd_t command,x;
 frame_rsp_t response,y;
 frame_meta_t meta,observed_meta;
 integer phase[0:2],identity[0:2],write_done_at[0:2],read_done_at[0:2];
 reg [31:0] gen[0:2],write_ticket[0:2],read_ticket[0:2];
 reg [2:0] write_token[0:2],read_token[0:2];
 integer checks=0,cycle=0,seed=32'h03102026,allocated=0,acquired=0,released=0;
 integer issue_slot,seal_slot,complete_slot,release_slot,i,s;
 integer stall_cycles=0,stall_run=0,max_alloc_wait=0,max_acquire_wait=0,max_retire_wait=0;
 integer multi_lane_cycles=0,lane_count;
 reg [2:0] occupied;reg [7:0] acquired_slots;
 always #5 clk=~clk;
 frame_pool_bank #(.TXNS(3)) pool(clk,reset_n,fabric_ready,1'b0,command,response);
 task tick;begin @(posedge clk);#1;end endtask
 task check(input logic ok,input string label_text);
 begin checks=checks+1;if(ok!==1'b1)begin
  $display("FRAME_MANAGER_PRESSURE_FAIL cycle=%0d %s",cycle,label_text);$fatal(1);
 end end endtask
 initial begin
  // Purpose: the command-line seed is recorded with metrics for replay.
  if($value$plusargs("SEED=%d",seed)) $display("PRESSURE_SEED=%0d",seed);
  command='0;
  for(i=0;i<3;i=i+1)begin phase[i]=0;identity[i]=0;write_done_at[i]=0;read_done_at[i]=0;end
  repeat(3)tick;reset_n=1;fabric_ready=1;tick;
  while(released<512 || response.occupied!=0) begin
   @(negedge clk);cycle=cycle+1;y=response;occupied=y.occupied;
   for(i=0;i<3;i=i+1)if(phase[i]==8 && !occupied[i])begin
    if(cycle-read_done_at[i]>max_retire_wait)max_retire_wait=cycle-read_done_at[i];
    check(cycle-read_done_at[i]<=2,"bounded recycle after final drain");phase[i]=0;
   end
   x='0;meta='0;meta.width=1920;meta.height=1080;meta.stride=6144;meta.format=2;
   meta.epoch=64'h100000002;meta.frame_id=allocated;meta.parameter_entity=allocated%7;
   x.alloc=allocated<512;x.meta=meta;x.consumers=1;x.acquire=1;
   issue_slot=-1;seal_slot=-1;complete_slot=-1;release_slot=-1;
   // Purpose: random wait injection is at the declared control/drain boundary;
   // no unsupported DDR response ordering or payload behavior is invented.
   for(i=0;i<3;i=i+1)begin
    if(issue_slot<0 && (phase[i]==1 || phase[i]==5) && ($random(seed)&3)!=0)issue_slot=i;
    if(seal_slot<0 && phase[i]==2 && ($random(seed)&3)!=0)seal_slot=i;
    if(complete_slot<0 && (phase[i]==3 || phase[i]==7) && ($random(seed)&3)==0)complete_slot=i;
    if(release_slot<0 && phase[i]==6 && ($random(seed)&3)!=0)release_slot=i;
   end
   if(issue_slot>=0)begin
    x.issue=1;x.issue_slot=issue_slot;x.issue_gen=gen[issue_slot];
    x.issue_owner=phase[issue_slot]==1?0:1;
   end
   if(seal_slot>=0)begin
    x.seal=1;x.seal_slot=seal_slot;x.seal_gen=gen[seal_slot];x.legal=1;x.capture_last=cycle;
   end
   if(complete_slot>=0)begin
    x.complete=1;x.complete_token=phase[complete_slot]==3?write_token[complete_slot]:read_token[complete_slot];
    x.complete_ticket=phase[complete_slot]==3?write_ticket[complete_slot]:read_ticket[complete_slot];
   end
   if(release_slot>=0)begin
    x.release_mask=1;x.release_slots=release_slot;x.release_gens=gen[release_slot];
   end
   command=x;#1;y=response;tick;command='0;
   check(!y.rejected,"legal modeled operations never reject");lane_count=0;
   if(x.alloc && y.alloc_ready)begin
    s=y.alloc_slot;check(phase[s]==0,"never overwrite a model-owned slot");
    phase[s]=1;gen[s]=y.alloc_gen;identity[s]=allocated;allocated=allocated+1;stall_run=0;lane_count=lane_count+1;
   end else if(x.alloc)begin
    stall_cycles=stall_cycles+1;stall_run=stall_run+1;
    if(stall_run>max_alloc_wait)max_alloc_wait=stall_run;
   end
   if(x.issue && y.issue_ready)begin
    if(phase[issue_slot]==1)begin write_token[issue_slot]=y.issue_token;write_ticket[issue_slot]=y.issue_ticket;phase[issue_slot]=2;end
    else begin read_token[issue_slot]=y.issue_token;read_ticket[issue_slot]=y.issue_ticket;phase[issue_slot]=6;end
    lane_count=lane_count+1;
   end
   if(x.seal && y.seal_ok)begin phase[seal_slot]=3;lane_count=lane_count+1;end
   if(x.complete && y.complete_ok)begin
    if(phase[complete_slot]==3)begin phase[complete_slot]=4;write_done_at[complete_slot]=cycle;end
    else begin phase[complete_slot]=8;read_done_at[complete_slot]=cycle;end
    lane_count=lane_count+1;
   end
   if(y.acquire_ok!=0)begin
    acquired_slots=y.acquire_slots;s=acquired_slots[1:0];observed_meta=y.acquire_meta;
    check(phase[s]==4,"no read of uncompleted write");
    check(identity[s]==acquired && observed_meta.frame_id==acquired,"source acquisition strictly ordered");
    check(observed_meta.parameter_entity==acquired%7 && observed_meta.epoch==64'h100000002,"parameter version/entity held per frame");
    if(cycle-write_done_at[s]>max_acquire_wait)max_acquire_wait=cycle-write_done_at[s];
    acquired=acquired+1;phase[s]=5;lane_count=lane_count+1;
   end
   if(x.release_mask!=0 && y.release_ok!=0)begin phase[release_slot]=7;released=released+1;lane_count=lane_count+1;end
   if(lane_count>1)multi_lane_cycles=multi_lane_cycles+1;
   if(cycle>30000)begin $display("FRAME_MANAGER_PRESSURE_TIMEOUT");$fatal(1);end
  end
  y=response;
  check(allocated==512 && acquired==512 && released==512,"all frame/owner counts conserved");
  check(y.published==512 && y.invalid_frames==0 && y.rejected_cycles==0,"complete frame telemetry exact");
  check(multi_lane_cycles>100 && y.peak_slots==3,"overlap and full-pool pressure exercised");
  $display("FRAME_MANAGER_PRESSURE_PASS checks=%0d cycles=%0d frames=512 max_alloc_wait=%0d max_acquire_wait=%0d max_retire_wait=%0d stalls=%0d overlap_cycles=%0d seed_final=%0d",
   checks,cycle,max_alloc_wait,max_acquire_wait,max_retire_wait,stall_cycles,multi_lane_cycles,seed);$finish;
 end
endmodule
