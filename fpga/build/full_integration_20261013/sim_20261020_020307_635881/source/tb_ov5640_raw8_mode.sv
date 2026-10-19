`timescale 1ns/1ps
// 用途：RAW8模式实体通过实际SCCB读改写服务完成43项写及最终整组核验；输入全为合成向量。
module tb_ov5640_raw8_mode #(parameter RAW_OUTPUT_SELECT=4);
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg apply=0,quiet=1;reg [19:0] exposure=20'd2560;
 wire ready,cmd,cmdready,wr,done,rejected,mode_ready,rsp;
 wire [15:0] addr;wire [7:0] value,mask,rsp_value;wire [31:0] cookie,rspcookie,version,entity;
 wire [2:0] status,rspstatus;
 tri1 scl,sda;
 integer starts,stops,writes,reads,nacks,checks=0;
 reg late_corruption=0;
 ov5640_raw8_mode #(.RAW_OUTPUT_SELECT(RAW_OUTPUT_SELECT)) mode(
 .clk(clk),.rst_n(rst_n),.quiesced(quiet),.apply(apply),.apply_ready(ready),
 .width(16'd1920),.height(16'd1080),.hts(16'd2500),.vts(16'd1125),
 .x_start(16'd336),.y_start(16'd434),.x_end(16'd2255),.y_end(16'd1513),.x_offset(16'd0),.y_offset(16'd0),
 .pll3034(8'h1a),.pll3035(8'h11),.pll3036(8'h3c),.pll3037(8'h13),.root3108(8'h01),
 .x_inc(8'h11),.y_inc(8'h11),.flip3820(8'h40),.mirror3821(8'h00),.bayer_code(3'd1),
 .exposure(exposure),.gain(10'h010),.requested_version(32'd8),.parameter_entity(32'd18),
 .cmd_valid(cmd),.cmd_ready(cmdready),.cmd_write(wr),.cmd_addr(addr),.cmd_value(value),.cmd_mask(mask),.cmd_cookie(cookie),
 .rsp_valid(rsp),.rsp_status(rspstatus),.rsp_value(rsp_value),.rsp_cookie(rspcookie),
 .done(done),.rejected(rejected),.status(status),.mode_ready(mode_ready),.active_version(version),.active_entity(entity));
 ov5640_register_service #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(80)) service(
 .clk(clk),.rst_n(rst_n),.init_finished(1'b1),.init_start(1'b0),.init_data(24'b0),
 .quiesced(quiet),.cmd_valid(cmd),.cmd_ready(cmdready),.cmd_write(wr),.cmd_addr(addr),
 .cmd_value(value),.cmd_mask(mask),.cmd_cookie(cookie),.rsp_valid(rsp),.rsp_status(rspstatus),
 .rsp_value(rsp_value),.rsp_cookie(rspcookie),.SCL(scl),.SDA(sda));
 ov5640_sccb_model sensor(rst_n,scl,sda,4'b0,1'b0,starts,stops,writes,reads,nacks);
 task check(input condition,input [511:0] label);
 begin checks=checks+1;if(condition!==1'b1)$fatal(1,"OV5640_RAW8_MODE_FAIL %0s",label);end endtask
 task submit;
 begin @(negedge clk);apply=1;@(negedge clk);apply=0;end endtask
 initial begin
  for(integer i=0;i<65536;i=i+1)sensor.memory[i]=0;
  sensor.memory[16'h300a]=8'h56;sensor.memory[16'h300b]=8'h40;
  sensor.memory[16'h3808]=8'ha0;sensor.memory[16'h380c]=8'he0;
  sensor.memory[16'h3820]=8'hc0;
  repeat(8)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);
  exposure=0;submit;wait(done);#1;check(status==5 && writes==0 && !mode_ready,"unknown exposure not silently inherited");
  repeat(8)@(negedge clk);exposure=2560;submit;repeat(10)@(negedge clk);submit;#1;check(rejected,"busy mode application rejected");exposure=8192;
  wait(done);#1;
  check(status==0 && mode_ready && version==8 && entity==18 && writes==43 && reads==132,"complete mode group and final verification");
  check({4'b0,sensor.memory[16'h3808][3:0],sensor.memory[16'h3809]}==1920 &&
   {5'b0,sensor.memory[16'h380a][2:0],sensor.memory[16'h380b]}==1080,"1080 dimensions readback");
  check(sensor.memory[16'h3808][7:4]==4'ha && sensor.memory[16'h380c][7:5]==3'h7 &&
   sensor.memory[16'h3820][7:3]==5'h18,"timing/flip debug fields preserved");
  // Both explicitly chosen RAW taps must survive the complete SCCB group and
  // final readback; this sensor-register model does not emulate crop geometry.
  check(sensor.memory[16'h4300]==3 && sensor.memory[16'h501f][2:0]==RAW_OUTPUT_SELECT,"explicit RAW tap and RGGB selection");
  check({sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}==20'd2560,
   "midgroup exposure input cannot change latched entity");exposure=2560;
  check(sensor.memory[16'h3503][1:0]==3 && sensor.memory[16'h350c]==0 && sensor.memory[16'h350d]==0,"fixed source exposure no extra rows");
  repeat(8)@(negedge clk);quiet=0;submit;wait(done);#1;check(status==6 && !mode_ready,"mode application requires drain");quiet=1;
  repeat(8)@(negedge clk);sensor.memory[16'h300b]=8'h41;submit;wait(done);#1;
  check(status==4 && writes==43 && !mode_ready,"identity failure makes no mode writes");
  repeat(8)@(negedge clk);sensor.memory[16'h300b]=8'h40;
  // 在最后一项已验证后、最终复核前破坏旧尺寸；不能仅靠逐项ACK发布版本。
  fork
   begin integer base_reads,base_writes;
    base_reads=reads;base_writes=writes;wait(writes==base_writes+43);
    wait(reads>=base_reads+89);sensor.memory[16'h3808]=0;end
   begin submit;wait(done);#1;check(status==3 && !mode_ready,"final group catches earlier register drift");end
  join
  $display("OV5640_RAW8_MODE_PASS checks=%d",checks);$finish;
 end
 initial begin #10000000;$fatal(1,"OV5640_RAW8_MODE_TIMEOUT");end
endmodule
