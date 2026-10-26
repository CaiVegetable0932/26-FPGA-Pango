`timescale 1ns/1ps
// Exercise the actual SCCB wire engine plus a buffered sensor model. Synthetic
// frame pulses validate ordering/atomicity, not real optical frame identity.
module tb_ov5640_group_exposure;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 tri1 SCL,SDA;reg apply=0;reg [19:0] exposure=3000;reg [9:0] gain=40;
 wire ready,done,busy,cv,cr,cw,rv;wire [2:0] error,rs;
 wire [15:0] ca;wire [7:0] value,returned;wire [31:0] cookie,rc;
 reg [3:0] nack_byte=0;integer starts,stops,writes,reads,nacks;
 reg override_command=0,override_valid=0,override_group=1;
 reg [15:0] override_addr=16'h380e;
 ov5640_group_exposure #(.TIMEOUT(180000)) dut(.clk(clk),.rst_n(rst_n),.apply(apply),.exposure(exposure),.gain(gain),
  .apply_ready(ready),.done(done),.error(error),.busy(busy),.cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),
  .cmd_addr(ca),.cmd_value(value),.cmd_cookie(cookie),.rsp_valid(rv),.rsp_status(rs),.rsp_value(returned),.rsp_cookie(rc));
 ov5640_register_service #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(100),.SERVICE_TIMEOUT(10000),.GROUP_EXPOSURE_ENABLE(1)) service(
  .clk(clk),.rst_n(rst_n),.init_finished(1'b1),.init_start(1'b0),.init_data(24'd0),.init_read(1'b0),
  .quiesced(1'b0),.cmd_group(override_command?override_group:1'b1),.cmd_valid(override_command?override_valid:cv),.cmd_ready(cr),
  .cmd_write(override_command?1'b1:cw),.cmd_addr(override_command?override_addr:ca),.cmd_value(override_command?8'hff:value),
  .cmd_mask(8'hff),.cmd_cookie(override_command?32'd0:cookie),.rsp_valid(rv),.rsp_status(rs),.rsp_value(returned),.rsp_cookie(rc),.SCL(SCL),.SDA(SDA));
 ov5640_sccb_model #(.GROUP_MODEL(1),.FRAME_NS(100000)) sensor(rst_n,SCL,SDA,nack_byte,1'b0,starts,stops,writes,reads,nacks);
 task initialize;
  begin
   @(negedge clk);rst_n=0;repeat(5)@(negedge clk);
   for(integer i=0;i<65536;i=i+1)sensor.memory[i]=0;
   sensor.memory[16'h3503]=3;sensor.memory[16'h380e]=4;sensor.memory[16'h380f]=8'h60;
   sensor.memory[16'h3500]=8'ha0;sensor.memory[16'h3501]=8'h07;sensor.memory[16'h3502]=8'hd0;
   sensor.memory[16'h350a]=8'hc0;sensor.memory[16'h350b]=32;
   sensor.group_latch_enable=1;nack_byte=0;rst_n=1;
  end
 endtask
 task request;
  begin wait(ready);@(negedge clk);apply=1;@(negedge clk);apply=0;end
 endtask
 initial begin
  initialize();sensor.group_latch_enable=0;request();
  wait(sensor.group_pending);repeat(2000)@(negedge clk);
  if(done || sensor.memory[16'h3501]!=7 || sensor.memory[16'h3502]!=8'hd0 || writes!=8)
   $fatal(1,"GROUP exposed partial write or completed before latch");
  sensor.group_latch_enable=1;wait(done);@(negedge clk);
  if(error!=0 || sensor.memory[16'h3500]!=8'ha0 || sensor.memory[16'h3501]!=11 || sensor.memory[16'h3502]!=184 ||
    sensor.memory[16'h350a]!=8'hc0 || sensor.memory[16'h350b]!=40 || writes!=8 || sensor.group_latches!=1)
   $fatal(1,"GROUP readback/reserved bits/atomic launch");
  // The trusted service rejects VTS even with privilege; generic live writes
  // remain forbidden, including the write-only group launch register itself.
  override_command=1;wait(cr);override_valid=1;@(negedge clk);override_valid=0;wait(rv);@(negedge clk);
  if(rs!=7 || writes!=8)$fatal(1,"GROUP privileged path permits timing write");
  override_group=0;override_addr=16'h3212;wait(cr);override_valid=1;@(negedge clk);override_valid=0;wait(rv);@(negedge clk);
  if(rs!=6 || writes!=8)$fatal(1,"GROUP bypass weakened generic quiesced guard");override_command=0;
  initialize();sensor.memory[16'h3213]=8'h20;request();wait(done);@(negedge clk);
  if(error!=3 || writes!=0)$fatal(1,"GROUP active group preflight guard");
  initialize();sensor.memory[16'h380f]=8'h61;request();wait(done);@(negedge clk);
  if(error!=3 || writes!=0)$fatal(1,"GROUP fixed VTS preflight guard");
  // NACK a buffered byte: no launch, no visible exposure mutation, error kept.
  initialize();request();wait(dut.index==12);nack_byte=4;wait(done);@(negedge clk);
  if(error!=1 || sensor.group_latches!=0 || sensor.memory[16'h3502]!=8'hd0)$fatal(1,"GROUP NACK did not abort");
  // A launch that never latches must time out rather than claim application.
  initialize();sensor.group_latch_enable=0;request();wait(done);@(negedge clk);
  if(error!=2 || sensor.group_latches!=0)$fatal(1,"GROUP stuck launch accepted");
  // Successful SCCB ACKs and an idle group status are insufficient: corrupt
  // one buffered byte and require readback mismatch to reach the deadline.
  initialize();sensor.group_latch_enable=0;request();wait(sensor.group_pending);
  sensor.group_value[2]=sensor.group_value[2]^1;sensor.group_latch_enable=1;wait(done);@(negedge clk);
  if(error!=2 || sensor.group_latches!=1)$fatal(1,"GROUP corrupt readback accepted");
  $display("OV5640_GROUP_EXPOSURE_PASS buffered latch, readback, reserved bits, NACK, group/VTS guards, timeout");$finish;
 end
 initial begin #10000000;$fatal(1,"GROUP_TEST_TIMEOUT");end
endmodule
