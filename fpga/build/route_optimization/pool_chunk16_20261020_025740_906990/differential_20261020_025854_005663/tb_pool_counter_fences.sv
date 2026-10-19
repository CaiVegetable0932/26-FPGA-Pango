`timescale 1ns/1ps
import frame_manager_pkg::*;
module tb_pool_counter_fences;
 reg clk=0,reset_n=0;always #5 clk=~clk;
 frame_cmd_t cmd;frame_rsp_t rsp;
 reg [63:0] seeds[0:4],held_ticket;integer i;
 frame_pool_bank #(.SLOTS(1),.TXNS(1)) dut(clk,reset_n,1'b1,1'b1,cmd,rsp);
 initial begin
  seeds[0]=64'hffff;seeds[1]=64'hffffffff;seeds[2]=64'hffffffffffff;
  seeds[3]=64'hfffffffffffffffe;seeds[4]=64'hffffffffffffffff;
  cmd='0;
  for(i=0;i<5;i=i+1)begin
   reset_n=0;cmd='0;repeat(3)@(negedge clk);reset_n=1;@(negedge clk);
   // Identical test-only deposits in independent implementations avoid
   // billions of transactions. Public operation/response checks remain live.
   dut.candidate.next_order=seeds[i];dut.reference_impl.next_order=seeds[i];
   dut.candidate.ticket[0]=seeds[i];dut.reference_impl.ticket[0]=seeds[i];
   cmd.alloc=1;cmd.meta.width=35;cmd.meta.height=33;cmd.meta.stride=6144;cmd.meta.format=2;
   cmd.meta.epoch=1;cmd.meta.frame_id=1;cmd.meta.capture_first=10;
   #1;
   if(i==4)begin
    if(rsp.alloc_ready)$fatal(1,"Order counter exhaustion wrapped");
    @(posedge clk);#3;
    if(dut.candidate.next_order!==seeds[i])$fatal(1,"Exhausted order counter changed");
   end else begin
    if(!rsp.alloc_ready)$fatal(1,"Boundary allocation not accepted");
    @(posedge clk);#3;
    if(dut.candidate.next_order!==(seeds[i]+64'd1))$fatal(1,"Order chunk carry");
    @(negedge clk);cmd='0;cmd.issue=1;cmd.issue_slot=0;cmd.issue_gen=1;cmd.issue_owner=0;
    #1;if(!rsp.issue_ready || rsp.issue_ticket!==(seeds[i]+64'd1))$fatal(1,"Ticket chunk carry response");
    held_ticket=rsp.issue_ticket;@(posedge clk);#3;
    if(dut.candidate.ticket[0]!==held_ticket)$fatal(1,"Ticket chunk state");
    @(negedge clk);cmd='0;cmd.complete=1;cmd.complete_ticket=held_ticket;cmd.complete_token=0;
    #1;if(!rsp.complete_ok)$fatal(1,"Boundary ticket did not retire");
    @(negedge clk);cmd='0;
   end
  end
  $display("POOL_COUNTER_FENCES_PASS");$finish;
 end
endmodule
