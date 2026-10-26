`timescale 1ns/1ps
// Purpose: actual analog/profile/service/mode startup through an SCCB sensor
// register model. It verifies stream remains off until all groups are checked.
module tb_ov5640_integrated_startup;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 tri1 SCL,SDA;wire sensor_reset_n,ready,failed;wire [3:0] failure_code;
 wire [31:0] active_version,active_entity;
 reg runtime_apply=0,runtime_quiesced=0,runtime_continuous=0;reg [19:0] runtime_exposure=2000;reg [9:0] runtime_gain=32;
 wire runtime_ready,runtime_done;wire [2:0] runtime_error;
 integer starts,stops,writes,reads,nacks,checks=0;
 ov5640_integrated_startup #(.SYS_CLK(3200),.SCCB_CLK(100),.RESET_CYCLES(8),.BOOT_CYCLES(8),
  .WRITE_WAIT(1),.SOFT_RESET_WAIT(4),.SERVICE_TIMEOUT(12000),.GROUP_TIMEOUT(1200000)) dut(.*);
 ov5640_sccb_model #(.GROUP_MODEL(1)) sensor(rst_n,SCL,SDA,4'b0,1'b0,starts,stops,writes,reads,nacks);
 initial begin
  for(integer a=0;a<65536;a++)sensor.memory[a]=0;
  sensor.memory[16'h300a]=8'h56;sensor.memory[16'h300b]=8'h40;
  repeat(8)@(negedge clk);rst_n=1;
  wait(ready || failed);@(negedge clk);
  if(failed)$fatal(1,"STARTUP_FAIL code=%0d writes=%0d reads=%0d",failure_code,writes,reads);
  // Each single-byte read deliberately ends with a master NACK; this is a
  // valid read termination, distinct from a slave refusing an address/write.
  if(writes!=362 || reads!=210 || nacks!=reads)$fatal(1,"STARTUP_FAIL complete transaction counts writes=%0d reads=%0d master_nacks=%0d",writes,reads,nacks);
  if(sensor.memory[16'h3008]!=2 || sensor.memory[16'h501f][2:0]!=3 ||
     sensor.memory[16'h3503][1:0]!=3 || sensor.memory[16'h5000]!=0 || sensor.memory[16'h5001]!=0)
   $fatal(1,"STARTUP_FAIL standby/raw/fixed exposure path");
  if({sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}!=10752 ||
     {sensor.memory[16'h3808][3:0],sensor.memory[16'h3809]}!=1920 ||
     {sensor.memory[16'h380a][2:0],sensor.memory[16'h380b]}!=1080 || active_version!=1 || active_entity!=1)
   $fatal(1,"STARTUP_FAIL fixed complete mode entity");
  repeat(20)@(negedge clk);if(!ready || writes!=362)$fatal(1,"STARTUP_FAIL repeated transactions");
  // Runtime commands use the same owner. Reject live writes, then perform a
  // complete paused group and verify the physical SCCB register model.
  wait(runtime_ready);runtime_apply=1;@(negedge clk);runtime_apply=0;
  wait(runtime_done);@(negedge clk);if(runtime_error!=6 || writes!=362)$fatal(1,"RUNTIME live write accepted");
  runtime_quiesced=1;wait(runtime_ready);runtime_apply=1;@(negedge clk);runtime_apply=0;
  wait(runtime_done);@(negedge clk);if(runtime_error!=0)$fatal(1,"RUNTIME update failed %d",runtime_error);
  repeat(3)@(negedge clk);
  if(!ready || writes!=374 || reads!=234 || sensor.memory[16'h3008]!=2 ||
   {sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}!=2000 ||
   {sensor.memory[16'h350a][1:0],sensor.memory[16'h350b]}!=32 ||
   {sensor.memory[16'h380e],sensor.memory[16'h380f]}!=1120 || !sensor.memory[16'h3406][0])$fatal(1,"RUNTIME readback/VTS/manual WB mismatch");
  // Live group request must retain ready and atomically change only shutter/gain.
  runtime_quiesced=0;runtime_continuous=1;runtime_exposure=3000;runtime_gain=40;
  wait(runtime_ready);runtime_apply=1;@(negedge clk);runtime_apply=0;
  wait(runtime_done);@(negedge clk);
  if(runtime_error!=0 || !ready || sensor.group_latches!=1 || writes!=382 ||
   {sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}!=3000 ||
   {sensor.memory[16'h350a][1:0],sensor.memory[16'h350b]}!=40 ||
   {sensor.memory[16'h380e],sensor.memory[16'h380f]}!=1120)$fatal(1,"LIVE_GROUP integrated failure");
  // A bad preflight fails closed. No stopped retry may assume that a failed
  // write-only group has been safely cancelled; reset is the recovery boundary.
  sensor.memory[16'h3213]=8'h20;wait(runtime_ready);runtime_apply=1;@(negedge clk);runtime_apply=0;
  wait(runtime_done);repeat(4)@(negedge clk);
  if(runtime_error!=3 || ready || runtime_ready || writes!=382)$fatal(1,"LIVE_GROUP failure quarantine");
  @(negedge clk);rst_n=0;repeat(8)@(negedge clk);sensor.memory[16'h300b]=8'h41;rst_n=1;
  wait(ready || failed);@(negedge clk);
  if(!failed || failure_code!=5 || writes!=0)$fatal(1,"STARTUP_FAIL wrong identity must precede any write");
  $display("OV5640_INTEGRATED_STARTUP_PASS initial_writes=362 initial_reads=210 runtime_writes=12 runtime_reads=24 wrong_id_writes=%0d",writes);$finish;
 end
 always @(posedge clk)if(rst_n && dut.group_busy && !ready)$fatal(1,"LIVE_GROUP interrupted DVP ready");
 always @(posedge clk)if(rst_n && dut.state>=2 && dut.state<8 && sensor.memory[16'h3008]==8'h02)
  $fatal(1,"STARTUP_FAIL streaming before verified complete mode");
 initial begin #30000000;$fatal(1,"STARTUP_TIMEOUT");end
endmodule
