`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: independently score every accepted descriptor/owner while four
// consumers contend. Exercise pause, cancellation, reset and exact-selector
// changes between request and ACK; no fixed implementation latency is assumed.
module tb_frame_metadata_read;
 reg clk=0,rst=0,ready=0;always #4 clk=~clk;
 frame_cmd_t command,action;
 frame_rsp_t response,observed;
 frame_meta_t metadata,got;
 reg [META_BITS-1:0] expected[0:2];
 reg [3:0] pending[0:2],owned[0:2];
 reg [31:0] generation[0:2];
 integer checks=0,accepted=0,slot_index,consumer,wait_cycles,i,n;
 reg [1:0] allocated_slot;
 reg [31:0] allocated_gen;
 // Flatten struct fields before dynamic indexing for the installed Icarus
 // parser; these aliases do not alter the observed handshake.
 wire [3:0] acquired=response.acquire_ok,released=response.release_ok,requested=command.acquire;
 frame_pool_bank #(.SLOTS(3),.TXNS(4)) pool(clk,rst,ready,1'b1,command,response);
 task check(input logic ok,input string label_text);
  begin checks++;if(ok!==1'b1)$fatal(1,"METADATA_READ_FAIL %s",label_text);end
 endtask
 task tick;begin @(posedge clk);#1;end endtask
 // Observe actual accepted edges, independently of the DUT's RAM and FSM.
 // Every bit of the 616-bit descriptor is compared, including full u64 IDs.
 always @(posedge clk)if(rst && ready)begin
  for(integer c=0;c<4;c=c+1)if(acquired[c])begin
   slot_index=(response.acquire_slots>>(2*c))&3;
   got=response.acquire_meta>>(META_BITS*c);
   check(requested[c] && slot_index<3,"ACK belongs to a requested consumer/valid slot");
   check(pending[slot_index][c] && !owned[slot_index][c],"one pending claim becomes exactly one reference");
   check((32'(response.acquire_gens>>(32*c)))==generation[slot_index],"exact generation retained");
   check(got===expected[slot_index],"all metadata bits retained at ACK");
   pending[slot_index][c]=0;owned[slot_index][c]=1;accepted++;
  end
  for(integer c=0;c<4;c=c+1)if(released[c])begin
   slot_index=(command.release_slots>>(2*c))&3;
   check(owned[slot_index][c],"release corresponds to an acquired reference");
   owned[slot_index][c]=0;
  end
 end
 task send(input frame_cmd_t request);
  begin @(negedge clk);command=request;#1;observed=response;tick;command='0;end
 endtask
 task allocate(input integer identity,input integer claims);
  begin
   // Populate all fields with nontrivial bits, overriding only legal shape
   // and explicitly mutable SEAL fields. This is not an all-zero payload test.
   metadata={20{32'h9876abcd^identity}};
   metadata.epoch=64'hfedcba9876543210;metadata.frame_id=64'h1234567800000000+identity;
   metadata.capture_first=64'habcdef0100000000+identity;
   metadata.capture_last=0;metadata.errors=0;
   metadata.width=1920;metadata.height=1080;metadata.stride=6144;metadata.format=2;
   action='0;action.alloc=1;action.meta=metadata;action.consumers=claims;
   @(negedge clk);command=action;#1;observed=response;
   check(observed.alloc_ready,"allocation available");allocated_slot=observed.alloc_slot;allocated_gen=observed.alloc_gen;
   expected[allocated_slot]=metadata;pending[allocated_slot]=claims;owned[allocated_slot]=0;generation[allocated_slot]=allocated_gen;
   tick;command='0;
   action='0;action.seal=1;action.seal_slot=allocated_slot;action.seal_gen=allocated_gen;
   action.legal=1;action.capture_last=metadata.capture_first+100;send(action);
   check(observed.seal_ok,"seal accepted");metadata.capture_last=action.capture_last;expected[allocated_slot]=metadata;
  end
 endtask
 task acquire_until(input integer target);
  begin wait_cycles=0;
   while(accepted<target && wait_cycles<32)begin tick;wait_cycles++;end
   check(accepted==target,"bounded fair acquisition");@(negedge clk);command='0;
  end
 endtask
 task release_all;
  begin
   for(integer s=0;s<3;s=s+1)if(owned[s]!=0)begin
    action='0;action.release_mask=owned[s];
    action.release_slots={4{2'(s)}};action.release_gens={4{generation[s]}};
    send(action);check(observed.release_ok==action.release_mask,"release all actual owners");
   end
   repeat(3)tick;check(response.occupied==0,"no slot/reference leak");
  end
 endtask
 initial begin
  command='0;for(i=0;i<3;i++)begin pending[i]=0;owned[i]=0;expected[i]=0;generation[i]=0;end
  repeat(3)tick;@(negedge clk);rst=1;ready=1;
  for(i=0;i<3;i++)allocate(i+1,15);
  @(negedge clk);command='0;command.acquire=15;
  acquire_until(12);release_all;

  // Pause after the RAM read edge but before acceptance. Inactive responses
  // stay zero; restarting must fetch/revalidate and produce exactly one ACK.
  allocate(10,1);@(negedge clk);command='0;command.acquire=1;
  tick;@(negedge clk);ready=0;
  repeat(3)begin tick;check(response.acquire_ok==0 && response.acquire_meta=='0,"quarantine masks ACK/payload");end
  check(accepted==12,"pause did not acquire");@(negedge clk);ready=1;
  acquire_until(13);release_all;

  // Cancellation has precedence over a prefetched descriptor.
  allocate(20,1);@(negedge clk);command='0;command.acquire=1;tick;
  @(negedge clk);command.cancel=1;command.cancel_slot=allocated_slot;command.cancel_gen=allocated_gen;
  #1;check(response.cancel_ok && response.acquire_ok==0,"cancel suppresses prefetched ACK");
  tick;command='0;pending[allocated_slot]=0;repeat(3)tick;
  check(accepted==13 && response.occupied==0,"cancel releases unacquired claim");

  // HISTORY follows the same oldest-pending ordering and generation fence.
  allocate(30,8);allocate(31,8);
  @(negedge clk);command='0;command.acquire=8;
  acquire_until(14);check(owned[0][3] && pending[1][3],"history acquires oldest source");
  @(negedge clk);command='0;command.acquire=8;
  acquire_until(15);release_all;

  // Reset after a speculative read must invalidate its tag. A fresh cold
  // allocation with new metadata is the only subsequent observable payload.
  allocate(40,1);@(negedge clk);command='0;command.acquire=1;tick;
  @(negedge clk);rst=0;command='0;for(i=0;i<3;i++)begin pending[i]=0;owned[i]=0;end
  repeat(3)tick;check(response.acquire_ok==0,"reset invalidates prefetched descriptor");
  @(negedge clk);rst=1;allocate(41,1);
  @(negedge clk);command='0;command.acquire=1;acquire_until(16);release_all;
  check(response.invalid_frames==0 && response.rejected_cycles==0,"fresh cold-reset telemetry clean");
  $display("TB_FRAME_METADATA_READ_PASS checks=%0d accepted=%0d",checks,accepted);$finish;
 end
 initial begin #200000;$fatal(1,"METADATA_READ timeout");end
endmodule
