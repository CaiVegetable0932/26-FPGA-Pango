`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: cross the old 32-bit ticket limit, reject a truncated completion,
// and verify final 64-bit exhaustion quarantines instead of wrapping/ABA.
module tb_frame_ticket_rollover;
 reg clk=0,rst=0;always #4 clk=~clk;
 frame_cmd_t command;frame_rsp_t response;reg [63:0] ticket;
 frame_pool_bank #(.SLOTS(1),.TXNS(1)) dut(.clk(clk),.reset_n(rst),.fabric_ready(1'b1),.display_boundary(1'b1),
  .cmd(command),.rsp(response));
 initial begin
  command='0;#100;rst=1;@(negedge clk);
  command.alloc=1;command.meta.width=35;command.meta.height=33;command.meta.stride=6144;command.meta.format=2;
  command.meta.epoch=1;command.meta.frame_id=1;command.meta.capture_first=10;
  #1;if(!response.alloc_ready)$fatal(1,"Allocation failed");@(negedge clk);command='0;
  // Test-only seed avoids billions of simulated transactions. Production has
  // no backdoor; its counter starts at zero and is retained until cold reset.
  dut.candidate.ticket[0]=64'h00000000ffffffff; dut.reference_impl.ticket[0]=64'h00000000ffffffff;
  command.issue=1;command.issue_slot=0;command.issue_gen=1;command.issue_owner=0;
  #1;if(!response.issue_ready || response.issue_ticket!=64'h0000000100000000)$fatal(1,"Ticket truncated at 32 bits");
  ticket=response.issue_ticket;@(negedge clk);command='0;
  command.complete=1;command.complete_token=0;command.complete_ticket=0;
  #1;if(response.complete_ok || !response.rejected)$fatal(1,"Truncated stale ticket retired a transaction");
  @(negedge clk);command.complete_ticket=ticket;
  #1;if(!response.complete_ok)$fatal(1,"Full ticket rejected");@(negedge clk);command='0;
  dut.candidate.ticket[0]=64'hfffffffffffffffe; dut.reference_impl.ticket[0]=64'hfffffffffffffffe;
  command.issue=1;command.issue_slot=0;command.issue_gen=1;command.issue_owner=0;
  #1;if(!response.issue_ready || response.issue_ticket!=64'hffffffffffffffff)$fatal(1,"Final ticket not issued");
  ticket=response.issue_ticket;@(negedge clk);command='0;command.complete=1;command.complete_token=0;command.complete_ticket=ticket;
  #1;if(!response.complete_ok)$fatal(1,"Final completion failed");@(negedge clk);command='0;
  command.issue=1;command.issue_slot=0;command.issue_gen=1;command.issue_owner=0;
  #1;if(response.issue_ready)$fatal(1,"Exhausted ticket wrapped");
  $display("TB_FRAME_TICKET_ROLLOVER_PASS checks=6");$finish;
 end
 initial begin #10000;$fatal(1,"Ticket timeout");end
endmodule
