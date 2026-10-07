`timescale 1ns/1ps
// Purpose: accepted reply snapshots must remain cycle-identical when wide
// capture enables are removed. Live buses change every cycle, including
// consecutive pushes, idle gaps, asynchronous reset and epoch flush.
module tb_mcu_snapshot_timing;
 reg clk=0,rst_n=0,accept=0,flush=0,geo=0;
 reg [255:0] payload=0;reg [95:0] geometry=0;
 reg [7:0] code=0;reg [15:0] seq=0;
 integer i,j,seed=32'h3ae21409,checks=0;reg [31:0] random_word;
 always #4 clk=~clk;
 mcu_protocol #(.GEOMETRY_CONTROL(1)) candidate(
  .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.link_epoch(64'd1),
  .link_epoch_valid(1'b1),.geometry_reply(geometry));
 mcu_protocol_golden #(.GEOMETRY_CONTROL(1)) golden(
  .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.link_epoch(64'd1),
  .link_epoch_valid(1'b1),.geometry_reply(geometry));
 initial begin
  // Isolate the capture stage; pin-level UART/queue regressions separately
  // verify admission capacity, byte serialization and CRC behavior.
  force candidate.push=accept;force golden.push=accept;
  force candidate.epoch_change=flush;force golden.epoch_change=flush;
  force candidate.response_payload=payload;force golden.response_payload=payload;
  force candidate.response_geometry=geo;force golden.response_geometry=geo;
  force candidate.response_code=code;force golden.response_code=code;
  force candidate.request_seq=seq;force golden.request_seq=seq;
  repeat(3)@(negedge clk);
  for(i=0;i<100000;i=i+1)begin
   random_word=$random(seed);rst_n=(i%193)!=0;
   accept=random_word[0];flush=(random_word[5:1]==0);geo=random_word[6];
   code=random_word[14:7];seq=$random(seed);
   for(j=0;j<8;j=j+1)payload[j*32+:32]=$random(seed);
   for(j=0;j<3;j=j+1)geometry[j*32+:32]=$random(seed);
   @(posedge clk);#1;
   if(candidate.pending_reply!==golden.pending_reply)$fatal(1,"SNAPSHOT_TIMING_FAIL valid");
   if(candidate.pending_reply)begin
    if({candidate.pending_command,candidate.pending_seq,candidate.queued_payload} !==
       {golden.pending_command,golden.pending_seq,golden.queued_payload})
     $fatal(1,"SNAPSHOT_TIMING_FAIL data cycle=%0d",i);
    checks=checks+1;
   end
   @(negedge clk);
  end
  if(checks<40000)$fatal(1,"SNAPSHOT_TIMING_FAIL insufficient coverage");
  $display("SNAPSHOT_TIMING_PASS cycles=100000 accepted=%0d",checks);$finish;
 end
endmodule
