`timescale 1ns/1ps
`include "frame_manager_layout.vh"
module frame_pool_bank #(
 parameter integer SLOTS=3,parameter [31:0] BASE=0,SLOT_BYTES=32'h00800000,
 parameter integer TXNS=8,parameter [31:0] STRIDE=6144
)(input wire clk,reset_n,fabric_ready,display_boundary,
 input wire [`FM_CMD_BITS-1:0] cmd,output wire [`FM_RSP_BITS-1:0] rsp);
 wire [`FM_RSP_BITS-1:0] reference_rsp;
 frame_pool_candidate #(.SLOTS(SLOTS),.BASE(BASE),.SLOT_BYTES(SLOT_BYTES),.TXNS(TXNS),.STRIDE(STRIDE))
 candidate(clk,reset_n,fabric_ready,display_boundary,cmd,rsp);
 frame_pool_reference #(.SLOTS(SLOTS),.BASE(BASE),.SLOT_BYTES(SLOT_BYTES),.TXNS(TXNS),.STRIDE(STRIDE))
 reference_impl(clk,reset_n,fabric_ready,display_boundary,cmd,reference_rsp);
 integer s,t,checks=0;
 task compare;
 begin
  if(reset_n)begin
   checks=checks+1;
   if(rsp !== reference_rsp) $fatal(1,"POOL_DIFF response (including invalid fields)");
`ifdef CHECK_LOCAL_FLAGS
   for(s=0;s<SLOTS;s=s+1)for(t=0;t<TXNS;t=t+1)
    if(candidate.slot_token_active[s][t] !== (candidate.token_busy[t] && candidate.token_slot[t]==s))
     $fatal(1,"POOL_DIFF token mirror s=%0d t=%0d",s,t);
`endif
`ifdef CHECK_COUNTER_STATE
   if(candidate.next_order !== reference_impl.next_order)
    $fatal(1,"POOL_DIFF full 64-bit order counter");
   for(t=0;t<TXNS;t=t+1)
    if(candidate.ticket[t] !== reference_impl.ticket[t] || candidate.token_busy[t] !== reference_impl.token_busy[t])
     $fatal(1,"POOL_DIFF full ticket/busy state t=%0d",t);
`endif
  end
 end endtask
 always @(posedge clk)begin #2;compare;end
 always @(negedge clk)begin #2;compare;end
 final $display("POOL_DIFF_CHECKS=%0d",checks);
endmodule
