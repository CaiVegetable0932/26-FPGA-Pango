`timescale 1ns/1ps
// Purpose: actual analog/profile/service/mode startup through an SCCB sensor
// register model. It verifies stream remains off until all groups are checked.
module tb_camera_apply_cdc;
 // Real asynchronous request/completion mailbox ahead of the complete sensor
 // startup. The source holds payload through done; target admission can stall.
 parameter real SOURCE_HALF=4.0,TARGET_HALF=18.5185,TARGET_PHASE=0.7;
 reg source_clk=0;always #SOURCE_HALF source_clk=~source_clk;
 reg source_valid=0,admit=1;wire source_ready,source_done,source_failed;
 wire cdc_valid;wire [30:0] cdc_payload;
 processing_job_cdc #(.JOB_BITS(31)) camera_apply_bridge(
  .source_clk(source_clk),.source_rst_n(rst_n),.source_valid(source_valid),.source_ready(source_ready),
  .source_job({runtime_continuous,runtime_exposure,runtime_gain}),.source_done(source_done),.source_failed(source_failed),
  .processing_clk(clk),.processing_rst_n(rst_n),.processing_valid(cdc_valid),.processing_ready(runtime_ready && admit),
  .processing_job(cdc_payload),.processing_done(runtime_done),.processing_failed(runtime_error!=0),
  // Mirror board use: scalar failure plus its existing held-error return.
  .processing_result(1'b0),.source_result());
 task send_request;
  begin wait(source_ready);@(negedge source_clk);source_valid=1;@(negedge source_clk);source_valid=0;end
 endtask
 integer accepted=0,completed=0;reg [30:0] last_capture;
 always @(posedge source_clk)if(rst_n)begin
  if(source_valid && source_ready)accepted<=accepted+1;
  if(source_done)begin
   completed<=completed+1;
   if(source_failed !== (runtime_error!=0))$fatal(1,"CDC error did not match held response");
  end
 end
 reg clk=0,rst_n=0;initial begin #TARGET_PHASE;forever #TARGET_HALF clk=~clk;end
 tri1 SCL,SDA;wire sensor_reset_n,ready,failed;wire [3:0] failure_code;
 wire [31:0] active_version,active_entity;
 reg runtime_apply=0,runtime_quiesced=0,runtime_continuous=0;reg [19:0] runtime_exposure=2000;reg [9:0] runtime_gain=32;
 wire runtime_ready,runtime_done;wire [2:0] runtime_error;
 integer starts,stops,writes,reads,nacks,checks=0;
 ov5640_integrated_startup #(.SYS_CLK(3200),.SCCB_CLK(100),.RESET_CYCLES(8),.BOOT_CYCLES(8),
  .WRITE_WAIT(1),.SOFT_RESET_WAIT(4),.SERVICE_TIMEOUT(12000),.GROUP_TIMEOUT(1200000)) dut(.runtime_apply(cdc_valid && admit),.runtime_exposure(cdc_payload[29:10]),
   .runtime_gain(cdc_payload[9:0]),.runtime_continuous(cdc_payload[30]),.*);
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
  admit=0;send_request();wait(cdc_valid);
  repeat(14)begin @(negedge clk);
   if(source_done || writes!=362 || runtime_done)$fatal(1,"CDC backpressure lost request isolation");
   if(cdc_payload!={runtime_continuous,runtime_exposure,runtime_gain})$fatal(1,"CDC held capture corrupted");
  end
  admit=1;
  wait(source_done);@(negedge clk);if(runtime_error!=6 || writes!=362)$fatal(1,"RUNTIME live write accepted");
  runtime_quiesced=1;
  // Bounds decisions must see the captured request after asynchronous offer.
  // A new legal source value before its request must not leak into the old
  // destination snapshot. This fails the former combinational borrowed bus.
  last_capture=cdc_payload;runtime_exposure=15;#1;
  if(cdc_payload!==last_capture)$fatal(1,"CDC raw source leaked into destination before request");
  send_request();wait(source_done);@(negedge clk);
  if(runtime_error!=5 || writes!=362)$fatal(1,"CDC low exposure accepted");
  runtime_exposure=17857;send_request();wait(source_done);@(negedge clk);
  if(runtime_error!=5 || writes!=362)$fatal(1,"CDC high exposure accepted");
  runtime_exposure=2000;runtime_gain=15;send_request();wait(source_done);@(negedge clk);
  if(runtime_error!=5 || writes!=362)$fatal(1,"CDC low gain accepted");
  runtime_gain=32;send_request();
  wait(source_done);@(negedge clk);if(runtime_error!=0)$fatal(1,"RUNTIME update failed %d",runtime_error);
  repeat(3)@(negedge clk);
  if(!ready || writes!=374 || reads!=234 || sensor.memory[16'h3008]!=2 ||
   {sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}!=2000 ||
   {sensor.memory[16'h350a][1:0],sensor.memory[16'h350b]}!=32 ||
   {sensor.memory[16'h380e],sensor.memory[16'h380f]}!=1120 || !sensor.memory[16'h3406][0])$fatal(1,"RUNTIME readback/VTS/manual WB mismatch");
  // Live group request must retain ready and atomically change only shutter/gain.
  runtime_quiesced=0;runtime_continuous=1;runtime_exposure=3000;runtime_gain=40;
  send_request();
  wait(source_done);@(negedge clk);
  if(runtime_error!=0 || !ready || sensor.group_latches!=1 || writes!=382 ||
   {sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}!=3000 ||
   {sensor.memory[16'h350a][1:0],sensor.memory[16'h350b]}!=40 ||
   {sensor.memory[16'h380e],sensor.memory[16'h380f]}!=1120)$fatal(1,"LIVE_GROUP integrated failure");
  // A bad preflight fails closed. No stopped retry may assume that a failed
  // write-only group has been safely cancelled; reset is the recovery boundary.
  sensor.memory[16'h3213]=8'h20;send_request();
  wait(source_done);repeat(4)@(negedge clk);
  if(runtime_error!=3 || ready || runtime_ready || writes!=382)$fatal(1,"LIVE_GROUP failure quarantine");
  // Cancel a captured but unadmitted request under common cold assertion.
  admit=0;send_request();wait(cdc_valid);repeat(3)@(negedge clk);
  @(negedge clk);rst_n=0;repeat(8)@(negedge clk);sensor.memory[16'h300b]=8'h41;rst_n=1;
  wait(ready || failed);@(negedge clk);
  if(!failed || failure_code!=5 || writes!=0)$fatal(1,"STARTUP_FAIL wrong identity must precede any write");
  repeat(10)@(negedge clk);
  if(source_done || cdc_valid || completed!=7 || accepted!=8)$fatal(1,"CDC duplicate or reset ghost accepted=%0d done=%0d",accepted,completed);
  $display("CAMERA_APPLY_CDC_PASS accepted=8 completed=7 reset_cancelled=1 stalled_cycles=14 bounds_rejected=3 startup=1 stopped=1 group=1 quarantine=1");$finish;
 end
 always @(posedge clk)if(rst_n && dut.group_busy && !ready)$fatal(1,"LIVE_GROUP interrupted DVP ready");
 always @(posedge clk)if(rst_n && dut.state>=2 && dut.state<8 && sensor.memory[16'h3008]==8'h02)
  $fatal(1,"STARTUP_FAIL streaming before verified complete mode");
 initial begin #200000000;$fatal(1,"STARTUP_TIMEOUT");end
endmodule
