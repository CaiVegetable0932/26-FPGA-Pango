`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: real frame_manager + DMA integration against an independent native
// memory scoreboard, including delayed visibility and corrupted EARLY beats.
// This tests RTL transactions; the model is not the vendor DDR timing model.
module tb_frame_memory_fabric;
 localparam N=6;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg controller_ready=1,display_boundary=0;
 reg [3*CMD_BITS-1:0] frame_command=0;
 wire [3*RSP_BITS-1:0] frame_response;
 reg [N-1:0] req_valid=0,req_write=0,urgent=0,cancel=0,w_valid=0,r_ready='1,done_ready=0;
 wire [N-1:0] req_ready,w_ready,r_valid,r_last,done,error,cancelled;
 reg [N*32-1:0] req_addr=0,req_tag=0,req_generation=0;
 reg [N*5-1:0] req_beats=0;
 reg [N*3-1:0] req_bank=0,req_owner=0;
 reg [N*2-1:0] req_slot=0;
 reg [N*256-1:0] w_data=0;reg [N*32-1:0] w_strb=0;
 wire [N*256-1:0] r_data;wire [N*32-1:0] done_tag,bus_bytes,max_wait_cycles,useful_write_bytes;
 wire fault,awvalid,arvalid;wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,awid,arid;
 reg awready=0,arready=0,native_wready=0,native_wlast=0,native_rvalid=0,native_rlast=0;
 wire [255:0] native_wdata;wire [31:0] native_wstrb;
 reg [255:0] native_rdata=0;reg [3:0] native_wid=0,native_rid=0;
 frame_memory_fabric dut(.*);
 byte mem[0:65535];
 integer wa=0,ra=0,wl=0,rl=0,wi=0,ri=0,cycle=0,checks=0,writes=0,reads=0;
 reg block_read=1,corrupt_early=0;
 // Invalid descriptor tests must not merely avoid payload transfer: even an
 // address VALID is forbidden throughout local rejection and its reply hold.
 reg rejection_only=0;
 always @(posedge clk)if(rst_n && rejection_only && (awvalid || arvalid))
  $fatal(1,"invalid descriptor reached native address channel");
 frame_cmd_t command;frame_rsp_t response;frame_meta_t meta;
 reg [1:0] slot;reg [31:0] generation;
 // The native side cannot be stalled on read data. Return gaps/address delays
 // vary with cycle count; writes honour masks and physical x32 word addresses.
 always @(negedge clk) begin
  awready=rst_n && wl==0 && cycle%7!=0;
  arready=rst_n && rl==0 && !block_read && cycle%5!=0;
  native_wready=rst_n && wl>0 && cycle%3!=0;native_wlast=wl==1;
  native_rvalid=rst_n && rl>0 && !block_read && cycle%4!=0;native_rlast=rl==1;
  for(integer q=0;q<32;q=q+1)native_rdata[q*8+:8]=mem[(ra+ri*32+q)%65536];
  if(corrupt_early && ri==0)native_rdata[7:0]=native_rdata[7:0]^8'h80;
 end
 always @(posedge clk) begin
  cycle=cycle+1;
  if(!rst_n)begin wl=0;rl=0;wi=0;ri=0;end
  else begin
   if(native_wready)begin
    for(integer q=0;q<32;q=q+1)if(native_wstrb[q])mem[(wa+wi*32+q)%65536]=native_wdata[q*8+:8];
    wi=wi+1;wl=wl-1;writes=writes+1;
   end
   if(native_rvalid)begin ri=ri+1;rl=rl-1;reads=reads+1;end
   if(awvalid && awready)begin wa=awaddr*4;wl=awlen+1;wi=0;end
   if(arvalid && arready)begin ra=araddr*4;rl=arlen+1;ri=0;end
  end
 end
 task check(input logic ok,input string label_text);
  begin checks++;if(ok!==1)$fatal(1,"FABRIC_FAIL cycle=%0d %s",cycle,label_text);end
 endtask
 task tick;begin @(posedge clk);#1;end endtask
 task action(input frame_cmd_t cmd);
  begin @(negedge clk);frame_command[0+:CMD_BITS]=cmd;#1;response=frame_response[0+:RSP_BITS];
   tick;frame_command=0;end
 endtask
 task allocate;
  begin command=0;meta=0;meta.width=32;meta.height=2;meta.stride=6144;meta.format=2;
   meta.epoch=64'h100000002;meta.frame_id=64'h300000004;
   command.alloc=1;command.meta=meta;command.consumers=1;action(command);
   check(response.alloc_ready,"allocate SRC");slot=response.alloc_slot;generation=response.alloc_gen;
  end
 endtask
 task automatic request(input integer client,input logic wr,input integer address,input integer beats,input integer owner);
  begin @(negedge clk);req_valid[client]=1;req_write[client]=wr;req_addr[client*32+:32]=address;
   req_tag[client*32+:32]=32'hface0000+client;req_beats[client*5+:5]=beats;req_bank[client*3+:3]=0;
   req_slot[client*2+:2]=slot;req_generation[client*32+:32]=generation;req_owner[client*3+:3]=owner;
   #1;while(!req_ready[client])begin @(negedge clk);#1;end
   @(posedge clk);@(negedge clk);req_valid[client]=0;
  end
 endtask
 task automatic payload(input integer client,input integer beats);
  begin
   for(integer p=0;p<beats;p=p+1)begin
    @(negedge clk);w_valid[client]=1;w_strb[client*32+:32]=(p==beats-1)?32'h0001ffff:32'hffffffff;
    for(integer q=0;q<32;q=q+1)w_data[client*256+q*8+:8]=8'(p*37+q+9);
    while(!w_ready[client])@(negedge clk);
    @(posedge clk);@(negedge clk);w_valid[client]=0;
   end
  end
 endtask
 task seal;
  begin command=0;command.seal=1;command.seal_slot=slot;command.seal_gen=generation;command.legal=1;
   action(command);check(response.seal_ok,"seal with writes still in flight");end
 endtask
 task cold_reset;
  begin @(negedge clk);rst_n=0;req_valid=0;w_valid=0;frame_command=0;cancel=0;done_ready=0;
   repeat(4)tick;@(negedge clk);rst_n=1;repeat(4)tick;end
 endtask
 initial begin
  for(integer m=0;m<65536;m=m+1)mem[m]=8'h5a;
  cold_reset;allocate;
  // A write token pins the slot after seal until ALL masked bytes read back.
  request(0,1,0,4,0);payload(0,4);seal;
  repeat(25)tick;response=frame_response[0+:RSP_BITS];
  check(writes==4 && reads==0 && !done[0] && response.published==0,"transport is not publication");
  command=0;command.acquire=1;action(command);check(response.acquire_ok==0,"no consumer before visibility");
  block_read=0;wait(done[0]);#1;check(!error[0] && !fault && reads==4,"every write beat verified");
  repeat(3)tick;response=frame_response[0+:RSP_BITS];check(response.published==1,"publish after fence");
  check(bus_bytes[31:0]==256 && useful_write_bytes[31:0]==113,"readback bus overhead measured");
  repeat(7)tick;check(done[0] && done_tag[31:0]==32'hface0000,"completion held until ACK");
  done_ready[0]=1;tick;done_ready=0;
  command=0;command.acquire=1;action(command);check(response.acquire_ok==1,"acquire immutable source");
  request(4,0,0,4,1);r_ready[4]=0;repeat(30)tick;
  check(!done[4],"unconsumed read keeps frame token");
  r_ready[4]=1;wait(done[4]);#1;check(!error[4] && !fault,"read drain retires token");
  done_ready[4]=1;tick;done_ready=0;
  request(4,0,0,4,1);cancel[4]=1;wait(done[4]);#1;
  response=frame_response[0+:RSP_BITS];
  check(cancelled[4] && !error[4] && response.invalid_frames==0,"read cancellation preserves stored frame");
  command=0;command.release_mask=1;command.release_slots[1:0]=slot;command.release_gens[31:0]=generation;
  action(command);check(response.release_ok==1,"release after cancelled read drain");
  // Corrupt only the first beat. A final-word-only fence would miss this case.
  cold_reset;block_read=0;corrupt_early=1;allocate;
  request(0,1,0,4,0);payload(0,4);seal;wait(fault);repeat(20)tick;
  response=frame_response[0+:RSP_BITS];
  check(response.published==0 && !done[0] && req_ready==0,"early corruption quarantines frame and fabric");
  // Cancellation after AW still drains native writes AND readback before retire.
  cold_reset;corrupt_early=0;block_read=1;allocate;
  request(0,1,0,2,0);payload(0,2);wait(arvalid);cancel[0]=1;seal;
  repeat(10)tick;check(!done[0],"cancel waits for visibility drain");
  block_read=0;wait(done[0]);#1;check(cancelled[0] && !fault,"cancelled write safely retires");
  response=frame_response[0+:RSP_BITS];check(response.published==0,"cancelled frame never published");
  // Range rejection is bounded and never creates a native write or frame token.
  cold_reset;allocate;
  begin integer before_count;before_count=writes;
   request(1,1,32'h01800000,1,0);wait(done[1]);#1;
   check(error[1] && writes==before_count && !fault,"cross-bank write rejected locally");
  end
  done_ready[1]=1;tick;done_ready=0;generation=generation+1;
  request(1,1,0,1,0);wait(done[1]);#1;
  check(error[1] && !fault,"stale generation rejected without native issue");
  // Withdrawn banks and unowned HISTORY/invalid owner reads cannot reach DDR.
  cold_reset;block_read=0;allocate;
  for(integer invalid_case=0;invalid_case<4;invalid_case=invalid_case+1)begin
   @(negedge clk);req_valid[5]=1;req_write[5]=0;req_beats[25+:5]=1;
   req_bank[15+:3]=invalid_case<2 ? invalid_case+3:0;
   req_addr[160+:32]=invalid_case==0 ? 32'h03c00000:invalid_case==1 ? 32'h04400000:0;
   req_owner[15+:3]=invalid_case==2 ? 5:4;req_slot[10+:2]=slot;req_generation[160+:32]=generation;
   tick;@(negedge clk);req_valid[5]=0;wait(done[5]);#1;
   check(error[5] && !fault,"withdrawn bank or unowned/invalid reader rejected");
   done_ready[5]=1;tick;@(negedge clk);done_ready=0;
  end
  // The wrapper proves all four checks removed from its specialized DMA.
  // Exercise each failure before token allocation, plus 33-bit wrap and slot
  // overrun. The same dual-DMA wrapper compares every statistic and handshake.
  for(integer shape_case=0;shape_case<6;shape_case=shape_case+1)begin
   cold_reset;block_read=0;allocate;rejection_only=1;
   case(shape_case)
    0:request(1,1,1,1,0);
    1:request(1,1,0,0,0);
    2:request(1,1,0,17,0);
    3:request(1,1,32'h00000fe0,2,0);
    4:request(1,1,32'hffffffe0,2,0);
    5:request(1,1,32'h007fffe0,2,0);
   endcase
   wait(done[1]);#1;check(error[1] && !fault,"shape check rejected before native issue");
   repeat(3)tick;done_ready[1]=1;tick;@(negedge clk);done_ready=0;rejection_only=0;
  end
  // All six producers can queue against the same bank, with independently
  // reserved data and unique tickets; no shared-bank completion may be lost.
  cold_reset;block_read=1;allocate;
  fork
   begin request(0,1,0,2,0);payload(0,2);end
   begin request(1,1,256,2,0);payload(1,2);end
   begin request(2,1,512,2,0);payload(2,2);end
   begin request(3,1,768,2,0);payload(3,2);end
   begin request(4,1,1024,2,0);payload(4,2);end
   begin request(5,1,1280,2,0);payload(5,2);end
  join
  seal;repeat(10)tick;response=frame_response[0+:RSP_BITS];
  check(response.published==0,"six writes retain publication fence");
  block_read=0;wait(done==6'h3f);repeat(3)tick;response=frame_response[0+:RSP_BITS];
  check(error==0 && !fault && response.published==1,"six unique completions publish exactly once");
  $display("FRAME_MEMORY_FABRIC_PASS checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"FABRIC_TIMEOUT");end
endmodule
