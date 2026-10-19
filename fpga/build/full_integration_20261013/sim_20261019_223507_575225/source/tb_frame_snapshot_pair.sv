`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: snapshot coordinator plus actual banks, modeling four independent
// copy transactions. Source ownership and pair export are checked separately.
module tb_frame_snapshot_pair;
 reg clk=0, reset_n=0, fabric_ready=0, display_boundary=0;
 frame_cmd_t external_command[0:4], combined[0:4];
 wire frame_cmd_t snapshot_command[0:4];
 wire frame_rsp_t response[0:4];
 wire [5*CMD_BITS-1:0] command_bus, snapshot_bus;
 wire [5*RSP_BITS-1:0] response_bus;
 genvar lane;
 generate for(lane=0;lane<5;lane=lane+1) begin
  assign command_bus[lane*CMD_BITS+:CMD_BITS]=combined[lane];
  assign snapshot_command[lane]=snapshot_bus[lane*CMD_BITS+:CMD_BITS];
  assign response[lane]=response_bus[lane*RSP_BITS+:RSP_BITS];
 end endgenerate
 reg request=0, cancel=0, copy_ready=0, copy_done=0, copy_error=0, copy_drained=0;
 reg [1:0] source_slot=0,result_slot=0;
 reg [31:0] source_gen=0,result_gen=0;
 wire request_ready,copy_valid,copy_cancel,pair_ready,busy,failed;
 wire [1:0] copy_ss,copy_rs;
 wire [31:0] copy_sg,copy_rg,snap_sg,snap_rg,completed,failures;
 wire frame_meta_t sm,rm;
 frame_cmd_t x; frame_rsp_t y; frame_meta_t m;
 integer checks=0,b,n,cycles=0;
 reg [2:0] tokens[0:4]; reg [31:0] tickets[0:4];
 reg [1:0] temp_slot; reg [31:0] temp_gen;
 always #5 clk=~clk;
 always @(posedge clk) cycles=cycles+1;
 // Purpose: field-disjoint command merging in the TB. Integration must reserve
 // these exact lanes for the snapshot controller; OR is not general arbitration.
 always @* for(integer i=0;i<5;i=i+1) combined[i]=external_command[i] | snapshot_command[i];
 frame_manager #(.BOARD_CLIENT_LIMITS(1)) dut(clk,reset_n,fabric_ready,display_boundary,command_bus,response_bus);
 frame_snapshot_pair #(.WAIT_CYCLES(160)) pair_ctrl(clk,reset_n,fabric_ready,
  request,cancel,source_slot,result_slot,source_gen,result_gen,request_ready,
  response_bus,snapshot_bus,copy_valid,copy_cancel,copy_ready,copy_done,copy_error,copy_drained,
  copy_ss,copy_rs,copy_sg,copy_rg,snap_sg,snap_rg,sm,rm,pair_ready,busy,failed,completed,failures);
 task tick; begin @(posedge clk); #1; end endtask
 task check(input logic ok,input string label_text);
 begin checks=checks+1; if(ok!==1'b1)begin
  $display("FRAME_SNAPSHOT_PAIR_FAIL cycle=%0d %s",cycles,label_text); $fatal(1);
 end end endtask
 task step(input integer bank,input frame_cmd_t action,output frame_rsp_t observed);
 begin @(negedge clk); external_command[bank]=action; #1; observed=response[bank];
  tick; external_command[bank]='0; #1;
 end endtask
 task allocate(input integer bank,input integer fid,input integer claims,
               output logic [1:0] s,output logic [31:0] g);
 begin x='0;m='0;m.epoch=77;m.frame_id=fid;m.width=1920;m.height=1080;m.stride=6144;
  m.format=2;m.stage=(bank==SRC)?1:3;m.parameter_entity=(bank==SRC)?11:22;
  m.isp_version=9;m.geometry_version=(bank==SRC)?0:19;
  x.alloc=1;x.meta=m;x.consumers=claims;step(bank,x,y);
  check(y.alloc_ready,"source allocation accepted");s=y.alloc_slot;g=y.alloc_gen;
  x='0;x.seal=1;x.seal_slot=s;x.seal_gen=g;x.legal=1;x.capture_last=100;
  step(bank,x,y);check(y.seal_ok,"source metadata committed");
 end endtask
 task submit_pair;
 begin @(negedge clk);request=1;#1;check(request_ready,"pair request admitted");tick;
  request=0; while(!copy_valid && busy)tick;
 end endtask
 task start_copy;
 begin check(copy_valid,"copy job exists");@(negedge clk);copy_ready=1;tick;copy_ready=0;
  for(b=0;b<5;b=b+1) if(b!=RAW) begin
   x='0;x.issue=1;x.issue_slot=(b==SRC)?source_slot:((b==DST)?result_slot:0);
   x.issue_gen=(b==SRC)?source_gen:((b==DST)?result_gen:((b==SNAP_S1)?snap_sg:snap_rg));
   x.issue_owner=(b==SRC || b==DST)?4:0;step(b,x,y);
   check(y.issue_ready,"copy transaction accounted");tokens[b]=y.issue_token;tickets[b]=y.issue_ticket;
  end
 end endtask
 task drain(input integer bank);
 begin x='0;x.complete=1;x.complete_token=tokens[bank];x.complete_ticket=tickets[bank];
  step(bank,x,y);check(y.complete_ok,"copy response drained");
 end endtask
 task export_release(input integer bank,input logic [31:0] g);
 begin x='0;x.acquire=4;step(bank,x,y);check(y.acquire_ok==4,"network acquires completed pair");
  x='0;x.release_mask=4;x.release_gens=128'(g)<<64;step(bank,x,y);check(y.release_ok==4,"export releases");
 end endtask
 initial begin
  for(b=0;b<5;b=b+1) external_command[b]='0;
  repeat(3)tick;reset_n=1;fabric_ready=1;tick;
  allocate(SRC,10,8,source_slot,source_gen);allocate(DST,10,8,result_slot,result_gen);
  submit_pair;check(sm.frame_id==rm.frame_id && sm.parameter_entity==11 && rm.parameter_entity==22,
   "same source with actual distinct stage parameters");start_copy;
  // Purpose: produced bytes and even destination write drain do not release
  // source reads or expose a partially copied pair.
  copy_done=1;drain(SNAP_S1);drain(SNAP_RESULT);repeat(5)tick;
  check(!pair_ready,"pair awaits source read drain");y=response[SRC];check(y.occupied!=0,"source held during copy");
  drain(SRC);drain(DST);copy_drained=1;
  while(!pair_ready)tick;copy_done=0;copy_drained=0;
  check(completed==1,"one complete pair published");repeat(3)tick;
  y=response[SRC];check(y.occupied==0,"S1 continuous slot released after copy");
  y=response[DST];check(y.occupied==0,"result continuous slot released after copy");
  // Purpose: frozen PC export consumes only snapshot storage while normal
  // frames continue. A second snapshot cannot reserve a source while BUSY.
  check(!request_ready,"snapshot BUSY during export");
  for(n=0;n<20;n=n+1) for(b=SRC;b<=DST;b=b+1)begin
   allocate(b,20+n,1,temp_slot,temp_gen);
   x='0;x.acquire=1;step(b,x,y);check(y.acquire_ok==1,"normal processing proceeds");
   x='0;x.release_mask=1;x.release_slots=temp_slot;x.release_gens=temp_gen;
   step(b,x,y);check(y.release_ok==1,"normal processing releases");tick;
  end
  export_release(SNAP_S1,snap_sg);repeat(3)tick;
  check(pair_ready && !request_ready,"releasing first image preserves second export admission");
  export_release(SNAP_RESULT,snap_rg);while(busy)tick;
  // Purpose: mismatched epoch/frame pairs fail before issuing a copy, release
  // source claims, and never publish a falsely same-source snapshot.
  allocate(SRC,50,8,source_slot,source_gen);allocate(DST,51,8,result_slot,result_gen);
  submit_pair;check(!copy_valid,"different source identities rejected");
  while(busy)tick;repeat(3)tick;check(failures==1,"mismatch failure counted");
  // Purpose: cancellation after copy acceptance waits for all four streams,
  // then invalidates destinations; new normal frames can use other slots.
  allocate(SRC,60,8,source_slot,source_gen);allocate(DST,60,8,result_slot,result_gen);
  submit_pair;start_copy;@(negedge clk);cancel=1;tick;cancel=0;
  repeat(3)tick;check(copy_cancel && busy && !pair_ready,"cancel requests drain");
  y=response[SRC];check(y.occupied!=0,"cancel cannot prematurely release source");
  drain(SRC);drain(DST);drain(SNAP_S1);drain(SNAP_RESULT);
  copy_drained=1;while(busy)tick;copy_drained=0;repeat(4)tick;
  check(failures==2 && completed==1,"cancelled copy never counted complete");
  // Purpose: export errors cancel the pair after copy ownership has already
  // drained; they must not wait for another stale copy_drained pulse. The slow
  // network owner remains protected until it explicitly releases its reference.
  allocate(SRC,61,8,source_slot,source_gen);allocate(DST,61,8,result_slot,result_gen);
  submit_pair;start_copy;drain(SRC);drain(DST);drain(SNAP_S1);drain(SNAP_RESULT);
  copy_done=1;copy_drained=1;while(!pair_ready)tick;copy_done=0;copy_drained=0;
  x='0;x.acquire=4;step(SNAP_S1,x,y);check(y.acquire_ok==4,"export owner obtains first image");
  x='0;x.issue=1;x.issue_slot=0;x.issue_gen=snap_sg;x.issue_owner=3;step(SNAP_S1,x,y);
  check(y.issue_ready,"export read accounted");tokens[SNAP_S1]=y.issue_token;tickets[SNAP_S1]=y.issue_ticket;
  x='0;x.complete=1;x.complete_token=tokens[SNAP_S1];x.complete_ticket=tickets[SNAP_S1];x.complete_error=1;
  step(SNAP_S1,x,y);check(y.complete_ok,"export failure drain accepted");
  while(busy)tick;repeat(3)tick;
  check(failures==3 && completed==2,"export failure exits without old copy drain");
  y=response[SNAP_S1];check(y.occupied!=0,"failed export retains network reference");
  x='0;x.release_mask=4;x.release_gens=128'(snap_sg)<<64;step(SNAP_S1,x,y);
  check(y.release_ok==4,"failed export releases retained owner");repeat(4)tick;
  // Missing handles timeout without silently retaining any normal frame.
  source_gen=32'hffff;result_gen=32'hffff;submit_pair;
  while(busy)tick;repeat(3)tick;check(failures==4,"unavailable request bounded timeout");
  for(b=0;b<5;b=b+1)begin y=response[b];check(y.occupied==0,"snapshot cleanup no leaks");end
  $display("FRAME_SNAPSHOT_PAIR_PASS checks=%0d cycles=%0d pairs=%0d failures=%0d",checks,cycles,completed,failures);$finish;
 end
 initial begin #2000000;$display("FRAME_SNAPSHOT_PAIR_TIMEOUT");$fatal(1);end
endmodule
