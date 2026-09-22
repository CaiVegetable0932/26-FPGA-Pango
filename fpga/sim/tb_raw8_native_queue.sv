`timescale 1ns/1ps
// Purpose: native asynchronous FIFO model with unequal clocks, full queue,
// arbitrary backpressure and coordinated startup reset. No behavioral FIFO substitute.
module tb_raw8_native_queue;
 parameter W=256;
 reg wc=0,rc=0,rst=0,valid=0,ready=0;
 reg [W-1:0] data=0;
 wire accept,out_valid;wire [W-1:0] out_data;wire [9:0] used;
 integer received=0,cycle=0,i,lane;
 reg full_seen=0;
 always #4 wc=~wc;
 always #6.7 rc=~rc;
 GTP_GRS GRS_INST(.GRS_N(rst));
 raw8_native_queue #(.WIDTH(W)) dut(wc,rst,data,valid,accept,used,rc,rst,out_data,out_valid,ready);
 always @(posedge rc)begin
  if(out_valid && ready)begin
   // A full sequence number prevents a 256-word alias from passing wrap tests.
   if(out_data[31:0]!==received)$fatal(1,"RAW8_FAIL native queue sequence");
   for(lane=4;lane<W/8;lane=lane+1)
    if(out_data[lane*8+:8]!==8'(received*13+lane))$fatal(1,"RAW8_FAIL native queue word=%0d lane=%0d",received,lane);
   received=received+1;
  end
 end
 always @(posedge wc)if(valid && !accept)full_seen<=1;
 always @(negedge rc)begin
  cycle=cycle+1;
  if(cycle>800)ready=cycle%17<11;
 end
 initial begin
  repeat(8)@(negedge wc);rst=1;repeat(16)@(negedge wc);
  for(i=0;i<4096;i=i+1)begin
   valid=1;for(lane=0;lane<W/8;lane=lane+1)data[lane*8+:8]=i*13+lane;
   data[31:0]=i;
   @(posedge wc);while(!accept)@(posedge wc);
   @(negedge wc);
  end
  valid=0;wait(received==4096);repeat(20)@(negedge rc);
  if(out_valid || !full_seen)$fatal(1,"RAW8_FAIL stale word or full case not exercised");
  $display("RAW8_NATIVE_QUEUE_PASS width=%0d words=%0d",W,received);$finish;
 end
 initial begin #2000000;$fatal(1,"RAW8_TIMEOUT native queue");end
endmodule
