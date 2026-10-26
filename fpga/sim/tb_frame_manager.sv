`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: adversarial control/DDR drain contract tests; no native DDR payload
// or hardware performance is inferred from these metadata-only transactions.
module tb_frame_manager;
 reg clk=0, reset_n=0, fabric_ready=0, display_boundary=0;
 frame_cmd_t command[0:2];
 wire frame_rsp_t response[0:2];
 wire [3*CMD_BITS-1:0] command_bus;
 wire [3*RSP_BITS-1:0] response_bus;
 genvar lane;
 generate for(lane=0;lane<3;lane=lane+1) begin
  assign command_bus[lane*CMD_BITS+:CMD_BITS]=command[lane];
  assign response[lane]=response_bus[lane*RSP_BITS+:RSP_BITS];
 end endgenerate
 frame_cmd_t x;
 frame_rsp_t y;
 frame_meta_t m, got;
 integer checks=0, cycles=0, b, n, j, seed=32'h310312, stall;
 reg [1:0] hslot[0:2], slot, other;
 reg [31:0] hgen[0:2], gen, oldgen;
 reg [2:0] toks[0:7], tok;
 reg [31:0] tickets[0:7], saved_ticket;
 always #5 clk=~clk;
 always @(posedge clk) cycles=cycles+1;
 frame_manager dut(clk,reset_n,fabric_ready,display_boundary,command_bus,response_bus);
 task tick; begin @(posedge clk); #1; end endtask
 task check(input logic ok,input string label_text);
 begin checks=checks+1; if(ok!==1'b1) begin
  $display("FRAME_MANAGER_FAIL cycle=%0d %s",cycles,label_text); $fatal(1);
 end end endtask
 // Purpose: sample ready/tag combinationally and commit exactly once, allowing
 // several operation lanes to execute on the same edge without testbench races.
 task step(input integer bank,input frame_cmd_t action,output frame_rsp_t observed);
 begin @(negedge clk); command[bank]=action; #1; observed=response[bank];
  tick; command[bank]='0; #1;
 end endtask
 task allocate(input integer bank,input integer fid,input logic [3:0] consumers,
               output logic [1:0] s,output logic [31:0] g);
 begin x='0; m='0; m.epoch=64'h123456789abcdef0; m.frame_id=64'h100000000+fid;
  m.width=1920; m.height=1080; m.stride=(bank==RAW)?2048:6144;
  m.format=(bank==RAW)?1:2; m.stage=bank; m.capture_first=fid*100;
  m.isp_version=17; m.geometry_version=23; m.enhancement_version=31;
  m.parameter_entity=101; m.calibration_entity=202; m.pose_entity=303;
  x.alloc=1; x.meta=m; x.consumers=consumers; step(bank,x,y);
  check(y.alloc_ready,"allocation accepted"); s=y.alloc_slot; g=y.alloc_gen;
  case(bank)
   SRC: check(y.alloc_base==s*32'h800000,"SRC byte address");
   DST: check(y.alloc_base==32'h1800000+s*32'h800000,"DST byte address");
   RAW: check(y.alloc_base==32'h3000000+s*32'h400000,"RAW byte address");
  endcase
 end endtask
 task seal_frame(input integer bank,input logic [1:0] s,input logic [31:0] g,input logic good);
 begin x='0; x.seal=1; x.seal_slot=s; x.seal_gen=g; x.legal=good;
  x.capture_last=64'hffffffff; step(bank,x,y); check(y.seal_ok,"metadata seal accepted");
 end endtask
 task issue_txn(input integer bank,input logic [1:0] s,input logic [31:0] g,
                input integer owner,output logic [2:0] token,output logic [31:0] ticket_value);
 begin x='0; x.issue=1; x.issue_slot=s; x.issue_gen=g; x.issue_owner=owner;
  step(bank,x,y); check(y.issue_ready,"transaction accepted");
  token=y.issue_token; ticket_value=y.issue_ticket;
 end endtask
 task drain(input integer bank,input logic [2:0] token,input logic [31:0] ticket_value,input logic error);
 begin x='0; x.complete=1; x.complete_token=token; x.complete_ticket=ticket_value;
  x.complete_error=error; step(bank,x,y); check(y.complete_ok,"unique drain accepted");
 end endtask
 task acquire_frame(input integer bank,input integer consumer,input logic [1:0] s,input logic [31:0] g);
 begin x='0; x.acquire=1<<consumer; step(bank,x,y);
  check(((y.acquire_ok>>consumer)&1)==1,"complete frame acquired");
  check(((y.acquire_slots>>(consumer*2))&3)==s,"ordered slot acquired");
  check((32'(y.acquire_gens>>(consumer*32)))==g,"acquire generation preserved");
  got=y.acquire_meta>>(consumer*META_BITS);
  check(got.epoch==64'h123456789abcdef0 && got.isp_version==17 &&
        got.geometry_version==23 && got.parameter_entity==101,"u64 identity/parameters atomic");
 end endtask
 task release_frame(input integer bank,input integer consumer,input logic [1:0] s,input logic [31:0] g);
 begin x='0; x.release_mask=1<<consumer; x.release_slots=8'(s)<<(2*consumer);
  x.release_gens=128'(g)<<(32*consumer); step(bank,x,y);
  check(((y.release_ok>>consumer)&1)==1,"consumer releases once");
 end endtask
 initial begin
  for(b=0;b<3;b=b+1) command[b]='0;
  repeat(3) tick; reset_n=1; tick;
  begin : allocate_disabled_test
   x='0; x.alloc=1; step(SRC,x,y); check(!y.alloc_ready,"fabric startup gate");
  end
  fabric_ready=1;
  // Purpose: earlier captures block later ready frames, and sealing is distinct
  // from retiring the final DDR write. Wrong/double completion cannot publish.
  allocate(SRC,1,4'b0001,hslot[0],hgen[0]);
  issue_txn(SRC,hslot[0],hgen[0],0,toks[0],tickets[0]);
  allocate(SRC,2,4'b0001,hslot[1],hgen[1]); seal_frame(SRC,hslot[1],hgen[1],1);
  x='0; x.acquire=1; step(SRC,x,y); check(y.acquire_ok==0,"later ready waits for oldest");
  seal_frame(SRC,hslot[0],hgen[0],1);
  x='0; x.acquire=1; step(SRC,x,y); check(y.acquire_ok==0,"seal before write drain not READY");
  drain(SRC,toks[0],tickets[0],0);
  acquire_frame(SRC,PROCESS,hslot[0],hgen[0]);
  acquire_frame(SRC,PROCESS,hslot[1],hgen[1]);
  release_frame(SRC,PROCESS,hslot[1],hgen[1]);
  release_frame(SRC,PROCESS,hslot[0],hgen[0]); repeat(3) tick;
  // Purpose: unique transaction tickets protect token reuse within one frame.
  allocate(SRC,3,4'b1111,slot,gen);
  for(n=0;n<8;n=n+1) issue_txn(SRC,slot,gen,0,toks[n],tickets[n]);
  x='0; x.issue=1; x.issue_slot=slot; x.issue_gen=gen; step(SRC,x,y);
  check(!y.issue_ready && !y.rejected,"finite transaction queue backpressure");
  drain(SRC,toks[3],tickets[3],0); saved_ticket=tickets[3];
  issue_txn(SRC,slot,gen,0,tok,oldgen);
  check(tok==toks[3] && oldgen!=saved_ticket,"same-frame ticket changes");
  x='0; x.complete=1; x.complete_token=tok; x.complete_ticket=saved_ticket;
  step(SRC,x,y); check(!y.complete_ok && y.rejected,"duplicate old token does not retire new work");
  seal_frame(SRC,slot,gen,1);
  for(n=7;n>=0;n=n-1) if(n!=3) begin
   stall=($random(seed)&7); repeat(stall) tick; drain(SRC,toks[n],tickets[n],0);
  end
  drain(SRC,tok,oldgen,0);
  x='0; x.acquire=15; step(SRC,x,y); check(y.acquire_ok==4'b1101,"display gated outside field boundary");
  display_boundary=1; acquire_frame(SRC,DISPLAY,slot,gen); display_boundary=0;
  issue_txn(SRC,slot,gen,DISPLAY+1,tok,saved_ticket);
  for(n=0;n<4;n=n+1) release_frame(SRC,n,slot,gen);
  repeat(2) tick; y=response[SRC]; check(y.occupied!=0,"release waits for read drain");
  drain(SRC,tok,saved_ticket,0); repeat(3) tick; y=response[SRC]; check(y.occupied==0,"all refs/transactions drained");
  // Purpose: cancellations drain old work; stale generation/release cannot hit
  // a recycled slot. Bad input/error responses never become readable frames.
  allocate(SRC,4,1,slot,gen); issue_txn(SRC,slot,gen,0,tok,saved_ticket);
  x='0; x.cancel=1; x.cancel_slot=slot; x.cancel_gen=gen; step(SRC,x,y);
  check(y.cancel_ok,"cancel accepted");
  allocate(SRC,5,1,other,oldgen); check(other!=slot,"cancelled in-flight slot protected");
  seal_frame(SRC,other,oldgen,0); drain(SRC,tok,saved_ticket,0); repeat(3) tick;
  hslot[0]=slot; hgen[0]=gen;
  allocate(SRC,6,1,slot,gen); check(slot==hslot[0] && gen!=hgen[0],"recycled generation increases");
  x='0; x.seal=1; x.seal_slot=slot; x.seal_gen=hgen[0]; x.legal=1;
  step(SRC,x,y); check(!y.seal_ok && y.rejected,"late frame completion rejected");
  issue_txn(SRC,slot,gen,0,tok,saved_ticket); drain(SRC,tok,saved_ticket,1);
  repeat(3) tick; y=response[SRC]; check(y.ready_frames==0 && y.occupied==0,"write error reclaimed");
  // Continuous SRC/RAW frames recycle independently without export slots.
  for(n=0;n<100;n=n+1) begin
   allocate(SRC,100+n,1,slot,gen); seal_frame(SRC,slot,gen,1);
   acquire_frame(SRC,PROCESS,slot,gen); release_frame(SRC,PROCESS,slot,gen); tick;
   allocate(RAW,100+n,4,slot,gen); seal_frame(RAW,slot,gen,1);
   acquire_frame(RAW,NETWORK,slot,gen); release_frame(RAW,NETWORK,slot,gen); tick;
  end
  // Purpose: pool full does not overwrite pending/owned frames; skipped RAW
  // reports whole-frame failure.
  for(n=0;n<3;n=n+1) allocate(RAW,300+n,4,hslot[n],hgen[n]);
  x='0; x.alloc=1; x.meta=m; step(RAW,x,y); check(!y.alloc_ready,"RAW pool full");
  for(n=0;n<3;n=n+1) begin
   x='0; x.skip_mask=4; x.release_slots=8'(hslot[n])<<4;
   x.release_gens=128'(hgen[n])<<64; step(RAW,x,y); check(y.skip_ok==4,"RAW failure counted");
   seal_frame(RAW,hslot[n],hgen[n],0);
  end
  repeat(4) tick;
  // Purpose: simultaneous control lanes preserve independent accounting, and
  // explicit error/cancel wins over new reads on the same edge.
  allocate(SRC,400,4'b0101,slot,gen);
  issue_txn(SRC,slot,gen,0,toks[0],tickets[0]);
  x='0;x.complete=1;x.complete_token=toks[0];x.complete_ticket=tickets[0];
  x.issue=1;x.issue_slot=slot;x.issue_gen=gen;x.issue_owner=0;step(SRC,x,y);
  check(y.complete_ok && y.issue_ready,"same cycle issue and drain");tok=y.issue_token;saved_ticket=y.issue_ticket;
  seal_frame(SRC,slot,gen,1);drain(SRC,tok,saved_ticket,0);
  acquire_frame(SRC,PROCESS,slot,gen);issue_txn(SRC,slot,gen,PROCESS+1,tok,saved_ticket);
  x='0;x.complete=1;x.complete_token=tok;x.complete_ticket=saved_ticket;x.complete_error=1;
  x.acquire=4;step(SRC,x,y);check(y.complete_ok && y.acquire_ok==0,"read error blocks same cycle new owner");
  release_frame(SRC,PROCESS,slot,gen);repeat(3)tick;
  allocate(SRC,401,1,slot,gen);seal_frame(SRC,slot,gen,1);
  x='0;x.cancel=1;x.cancel_slot=slot;x.cancel_gen=gen;x.acquire=1;
  step(SRC,x,y);check(y.cancel_ok && y.acquire_ok==0,"cancel blocks same cycle acquire");repeat(3)tick;
  allocate(SRC,402,1,slot,gen);seal_frame(SRC,slot,gen,1);
  acquire_frame(SRC,PROCESS,slot,gen);release_frame(SRC,PROCESS,slot,gen);
  x='0;x.release_mask=1;x.release_slots=slot;x.release_gens=gen;step(SRC,x,y);
  check(y.release_ok==0 && y.rejected,"duplicate release rejected without underflow");repeat(3)tick;
  x='0;x.alloc=1;x.meta=m;m.width=65535;x.meta=m;step(SRC,x,y);
  check(!y.alloc_ready && y.rejected,"invalid row dimensions rejected");
  for(b=0;b<3;b=b+1) begin y=response[b]; check(y.occupied==0,"no slot leaks"); end
  // Reset is tested only with no live DDR work: a local-only reset is forbidden.
  fabric_ready=0; reset_n=0; tick; reset_n=1; tick;
  y=response[SRC]; check(y.occupied==0 && y.published==0,"cold reset after fabric flush");
  // Purpose: payload-only registers deliberately retain arbitrary bits across
  // cold reset. Model X-filled unused storage after every prior transaction has
  // drained; this is a joint fabric/controller/CDC reset, never a local reset
  // of live DDR work. Invalid slots/tokens must not leak X onto response fields.
  @(negedge clk); reset_n=0;
  for(n=0;n<3;n=n+1) begin
   dut.banks[SRC].pool.metadata[n]='x;
   dut.banks[SRC].pool.order_id[n]='x;
  end
  for(n=0;n<8;n=n+1) begin
   dut.banks[SRC].pool.token_slot[n]='x;
   dut.banks[SRC].pool.token_gen[n]='x;
   dut.banks[SRC].pool.token_owner[n]='x;
  end
  tick; fabric_ready=1; display_boundary=1;
  x='0; x.acquire=15; command[SRC]=x; #1; y=response[SRC];
  check(y.occupied===0 && y.ready_frames===0 && y.acquire_ok===0 &&
        y.acquire_meta==='0,"X-filled invalid payload never escapes acquisition");
  // Keep a legal allocation plus stale ownership/transaction commands present
  // while reset is asserted and fabric_ready stays high. ALLOC_READY may still
  // advertise a free slot; reset must prevent that advertisement from making a
  // busy slot or accepting an uninitialized token/descriptor. Payload may change.
  m='0; m.epoch=64'h123456789abcdef0; m.frame_id=64'h1234567800000500;
  m.capture_first=64'h70000002; m.capture_last=64'h70000003;
  m.isp_version=17; m.geometry_version=23; m.enhancement_version=31;
  m.calibration_entity=202; m.parameter_entity=101; m.pose_entity=303;
  m.mode=32'h01020304; m.stride=6144; m.width=1920; m.height=1080; m.format=2;
  m.stage=8'h31; m.enhancement_stage=8'h02; m.pose_status=8'h05;
  x='0; x.alloc=1; x.meta=m; x.consumers=1; x.acquire=15;
  x.issue=1; x.issue_gen=1; x.issue_owner=0;
  x.complete=1; x.complete_ticket=1; x.complete_error=1;
  command[SRC]=x;
  repeat(3) begin
   tick; y=response[SRC];
   check(y.occupied===0 && y.ready_frames===0 && y.acquire_ok===0 &&
         y.acquire_meta==='0 && y.issue_ready===0 && y.complete_ok===0 &&
         y.published===0 && y.invalid_frames===0 && y.rejected_cycles===0,
         "ready-high reset keeps held commands and X payload inactive");
  end
  // Poison the would-be slot again immediately before releasing reset, then
  // commit the already-held ALLOC on the first edge. Every metadata/order bit
  // must be written on that same edge, before busy/pending exposes the slot.
  @(negedge clk); dut.banks[SRC].pool.metadata[0]='x;
  dut.banks[SRC].pool.order_id[0]='x;
  reset_n=1; #1; y=response[SRC]; slot=y.alloc_slot; gen=y.alloc_gen;
  check(y.alloc_ready===1 && slot===0 && gen===1,"first cold-reset allocation advertises known handle");
  tick; command[SRC]='0; display_boundary=0; #1; y=response[SRC];
  check(y.occupied===3'b001 && y.ready_frames===0,"first cold-reset allocation commits exactly one slot");
  check(dut.banks[SRC].pool.metadata[0]===m && dut.banks[SRC].pool.order_id[0]===64'd0,
        "first allocation fully replaces X descriptor and order payload");
  issue_txn(SRC,slot,gen,0,tok,saved_ticket);
  check(tok===0 && saved_ticket===1,"first issue initializes token and preserved ticket counter");
  seal_frame(SRC,slot,gen,1); drain(SRC,tok,saved_ticket,0);
  acquire_frame(SRC,PROCESS,slot,gen);
  m.capture_last=64'hffffffff;
  check(got===m,"first acquire preserves every descriptor bit with sealed capture time");
  release_frame(SRC,PROCESS,slot,gen); repeat(3)tick;
  y=response[SRC]; check(y.occupied===0 && y.ready_frames===0 && y.acquire_meta==='0,
                       "cold-reset test releases all ownership without X leakage");
  $display("FRAME_MANAGER_PASS checks=%0d cycles=%0d sustained_frames_per_pool=100",checks,cycles); $finish;
 end
 initial begin #2000000; $display("FRAME_MANAGER_TIMEOUT"); $fatal(1); end
endmodule
