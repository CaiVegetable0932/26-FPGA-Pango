`timescale 1ns/1ps
// Requests in the middle of a source never mutate active work. Exact retries
// ACK once; a conflicting action with the same recent request_seq is rejected.
module tb_frame_runtime_actions;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,submit=0,boundary=0;
 reg [15:0] action=3,seq=41;reg [63:0] frame=10;wire [7:0] code;
 wire motion_clear,history_clear;wire [319:0] status;integer resets=0,clears=0;
 frame_runtime_actions dut(.clk(clk),.rst_n(rst_n),.submit_valid(submit),.action(action),.request_seq(seq),.submit_code(code),
  .capture_boundary(boundary),.epoch(64'd8),.frame_id(frame),.clear_motion(motion_clear),.clear_history(history_clear),.status_extension(status));
 always @(posedge clk)if(rst_n)begin if(motion_clear)resets=resets+1;if(history_clear)clears=clears+1;end
 task request(input [15:0] a,s,input [7:0] expected);begin
  @(negedge clk);action=a;seq=s;#1;if(code!=expected)$fatal(1,"action=%d seq=%d code=%d expected=%d",a,s,code,expected);
  submit=1;@(negedge clk);submit=0;
 end endtask
 task capture(input [63:0] id);begin
  @(negedge clk);frame=id;boundary=1;@(negedge clk);boundary=0;
 end endtask
 initial begin
  // Retired reset has no effect; retained history clear keeps retry/boundary fences.
  #21;rst_n=1;request(3,40,6);request(4,41,0);repeat(5)@(negedge clk);
  if(resets || clears || status[7:0]!=2)$fatal(1,"midframe action ran early");
  request(4,41,0);request(3,41,6);request(4,42,4);
  capture(11);if(resets!=0 || clears!=1 || status[7:0]!=0 || status[15:8]!=4 || status[64+:64]!=8 || status[128+:64]!=11 || status[192+:16]!=41)$fatal(1,"clear boundary identity");
  request(4,41,0);capture(12);if(resets!=0 || clears!=1)$fatal(1,"completed retry repeated action");
  request(4,42,0);capture(13);if(resets!=0 || clears!=2 || status[128+:64]!=13)$fatal(1,"clear history semantics");
  request(7,43,6);capture(14);if(clears!=2)$fatal(1,"unsupported action executed");
  $display("PASS runtime actions frame-boundary/retry/conflict/busy/status");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
