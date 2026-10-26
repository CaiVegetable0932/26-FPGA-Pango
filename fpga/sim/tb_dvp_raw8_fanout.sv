`timescale 1ns/1ps
// 用途：不可暂停分流的分支独立过载、共享错误、无令牌、下帧恢复和同源tag验证。
module tb_dvp_raw8_fanout;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg start=0,admit=1,abort=0,finish=0,legal=1,raw_admit=1,isp_admit=1;
 reg valid=0,raw_ready=1,isp_ready=1;reg [7:0] data=0;reg [15:0] x=0,y=0;
 wire rv,iv,rabort,iabort,rend,iend,rlegal,ilegal;wire [7:0] rd,id;
 wire [31:0] rdrops,idrops;
 wire [159:0] tag;
 integer raw_count=0,isp_count=0,checks=0;
 dvp_raw8_fanout dut(.pclk(clk),.rst_n(rst_n),.frame_start(start),.frame_admitted(admit),
 .frame_abort(abort),.frame_end(finish),.frame_legal(legal),.raw_admit(raw_admit),.isp_admit(isp_admit),
 .in_valid(valid),.in_raw(data),.in_x(x),.in_y(y),.in_sof(x==0),.in_eol(x==11),.in_last(x==11),
 .in_tag(160'h123),.raw_ready(raw_ready),.isp_ready(isp_ready),.raw_valid(rv),.isp_valid(iv),
 .raw_data(rd),.isp_data(id),.out_tag(tag),.raw_abort(rabort),.isp_abort(iabort),
 .raw_end(rend),.isp_end(iend),.raw_legal(rlegal),.isp_legal(ilegal),
 .raw_dropped_frames(rdrops),.isp_dropped_frames(idrops));
 always @(posedge clk)if(rst_n)begin
  if(rv && raw_ready)begin raw_count=raw_count+1;if(rd!=data || tag!=160'h123)$fatal(1,"RAW_FORK_DATA");end
  if(iv && isp_ready)begin isp_count=isp_count+1;if(id!=data || tag!=160'h123)$fatal(1,"ISP_FORK_DATA");end
 end
 task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
 task check(input condition,input [511:0] label);
 begin checks=checks+1;if(condition!==1'b1)$fatal(1,"DVP_RAW8_FANOUT_FAIL %0s",label);end endtask
 task frame(input integer raw_full_at,input integer isp_full_at);
 begin
  raw_count=0;isp_count=0;start=1;tick;start=0;
  for(integer i=0;i<12;i=i+1)begin
   valid=1;x=i;data=i+8'h20;raw_ready=(i!=raw_full_at);isp_ready=(i!=isp_full_at);tick;
  end
  valid=0;finish=1;tick;check(rend && iend,"both frame end events survive data drop");finish=0;
 end endtask
 initial begin
  repeat(5)tick;rst_n=1;tick;
  frame(-1,-1);check(rlegal && ilegal && raw_count==12 && isp_count==12,"parallel identical complete stream");
  frame(4,-1);check(!rlegal && ilegal && raw_count==4 && isp_count==12 && rdrops==1,"RAW overload independent of ISP");
  frame(-1,6);check(rlegal && !ilegal && raw_count==12 && isp_count==6 && idrops==1,"ISP overload independent of RAW");
  frame(-1,-1);check(rlegal && ilegal,"next frame resumes with new admission");
  raw_admit=0;frame(-1,-1);check(!rlegal && ilegal && raw_count==0 && rdrops==2,"no RAW slot cannot block primary video");raw_admit=1;
  start=1;tick;start=0;valid=1;abort=1;tick;abort=0;valid=0;finish=1;legal=0;tick;
  check(!rlegal && !ilegal && rdrops==3 && idrops==2,"common frame error poisons both branches once");
  $display("DVP_RAW8_FANOUT_PASS checks=%d",checks);$finish;
 end
 initial begin #100000;$fatal(1,"DVP_RAW8_FANOUT_TIMEOUT");end
endmodule
