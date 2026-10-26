`timescale 1ns/1ps
// 用途：带开漏引脚模型的运行期查询/读改写/回读、初始化所有权和有界异常验证。
module tb_ov5640_register_service;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg init_finished=0,init_start=0,quiet=1,cmd=0,write_op=0,stretch=0;
 reg [23:0] init_data=24'h300802;reg [15:0] address=0;reg [7:0] value=0,mask=0;
 reg [31:0] cookie=0;reg [3:0] nack=0;
 tri1 scl,sda;assign scl=stretch ? 1'b0 : 1'bz;
 wire init_end,init_failed,ready,rejected,rsp;wire [2:0] status;
 wire [7:0] returned;wire [15:0] rsp_addr;wire [31:0] rsp_cookie;
 integer starts,stops,writes,reads,nacks,checks=0;
 ov5640_register_service #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(80),.SERVICE_TIMEOUT(10000)) dut(
 .clk(clk),.rst_n(rst_n),.init_finished(init_finished),.init_start(init_start),.init_data(init_data),
 .init_end(init_end),.init_failed(init_failed),.quiesced(quiet),.cmd_valid(cmd),.cmd_ready(ready),
 .cmd_write(write_op),.cmd_addr(address),.cmd_value(value),.cmd_mask(mask),.cmd_cookie(cookie),
 .cmd_rejected(rejected),.rsp_valid(rsp),.rsp_status(status),.rsp_value(returned),.rsp_addr(rsp_addr),.rsp_cookie(rsp_cookie),
 .SCL(scl),.SDA(sda));
 ov5640_sccb_model sensor(rst_n,scl,sda,nack,1'b0,starts,stops,writes,reads,nacks);
 task check(input condition,input [511:0] label);
 begin checks=checks+1;if(condition!==1'b1)$fatal(1,"OV5640_REGISTER_SERVICE_FAIL %0s",label);end endtask
 task issue(input wr,input [15:0] addr,input [7:0] v,m,input [31:0] id);
 begin @(negedge clk);write_op=wr;address=addr;value=v;mask=m;cookie=id;cmd=1;@(negedge clk);cmd=0;end endtask
 task response(input [2:0] expected);
 begin wait(rsp);#1;check(status==expected,"response status");repeat(8)@(negedge clk);end endtask
 initial begin
  sensor.memory[16'h300a]=8'h56;sensor.memory[16'h3503]=8'ha0;
  repeat(8)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);
  check(!ready,"init owns bus");issue(0,16'h300a,0,0,1);#1;check(rejected,"query rejected during init");
  @(negedge clk);init_start=1;@(negedge clk);init_start=0;wait(init_end);#1;check(!init_failed && writes==1,"init write success");
  repeat(8)@(negedge clk);init_finished=1;
  issue(0,16'h300a,0,0,32'h1234);repeat(10)@(negedge clk);issue(0,16'h3503,0,0,32'hdead);
  #1;check(rejected,"busy rejects second request");wait(rsp);#1;
  check(returned==8'h56 && rsp_cookie==32'h1234 && rsp_addr==16'h300a,"latched read identity");
  repeat(8)@(negedge clk);issue(1,16'h3503,8'h03,8'h03,2);response(0);
  check(sensor.memory[16'h3503]==8'ha3,"masked write preserves upper bits");
  quiet=0;issue(1,16'h3503,0,8'h03,3);response(6);check(writes==2,"unquiesced write never reaches sensor");quiet=1;
  issue(1,16'h300a,0,8'hff,4);response(7);check(writes==2,"read-only ID protected");
  issue(1,16'h3503,0,0,5);response(5);check(writes==2,"zero mask rejected");
  nack=1;issue(0,16'h300a,0,0,6);response(1);nack=0;
  issue(0,16'h300a,0,0,7);wait(dut.bus.busy);@(negedge scl);stretch=1;response(2);stretch=0;
  repeat(8)@(negedge clk);check(scl===1'b1 && sda===1'b1,"timeout releases bus");
  fork
   begin wait(writes==3);sensor.memory[16'h3503]=8'hff;end
   begin issue(1,16'h3503,0,8'h03,8);response(3);end
  join
  check(writes==3,"mismatch reports failure without retry");
  fork
   begin integer baseline;baseline=reads;wait(reads>baseline);quiet=0;end
   begin issue(1,16'h3503,0,8'h03,9);response(6);end
  join
  check(writes==3,"quiesce loss before write aborts transaction");
  $display("OV5640_REGISTER_SERVICE_PASS checks=%d",checks);$finish;
 end
 initial begin #2000000;$fatal(1,"OV5640_REGISTER_SERVICE_TIMEOUT");end
endmodule
