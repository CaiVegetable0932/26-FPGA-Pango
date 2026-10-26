`timescale 1ns/1ps
// 用途：有限深度队列与并行服务停顿模型，验证容量内突发/满队列整帧作废/排空后重同步。
// 队列仅是同步事务模型；实际跨域必须使用01签核的原生FIFO与独立事件通路。
module tb_dvp_raw8_queues;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg start=0,finish=0,valid=0;reg [7:0] data=0;reg [15:0] x=0;
 reg raw_service=1,isp_service=1;
 wire rv,iv,rabort,iabort,rlegal,ilegal;
 integer rq=0,iq=0,rhead=0,ihead=0,rtail=0,itail=0,rpeak=0,ipeak=0;
 integer rread=0,iread=0,checks=0;reg raw_poison=0,isp_poison=0;
 reg [7:0] rmem[0:7],imem[0:7];
 wire raw_ready=rq<8,isp_ready=iq<8;
 dvp_raw8_fanout dut(.pclk(clk),.rst_n(rst_n),.frame_start(start),.frame_admitted(1'b1),
 .frame_abort(1'b0),.frame_end(finish),.frame_legal(1'b1),.raw_admit(rq==0),.isp_admit(iq==0),
 .in_valid(valid),.in_raw(data),.in_x(x),.in_y(16'b0),.in_sof(x==0),.in_eol(x==31),.in_last(x==31),
 .in_tag(160'h42),.raw_ready(raw_ready),.isp_ready(isp_ready),.raw_valid(rv),.isp_valid(iv),
 .raw_abort(rabort),.isp_abort(iabort),.raw_legal(rlegal),.isp_legal(ilegal));
 // 先锁存ready/valid，再执行读写，避免模型的blocking队列更新改变同拍接受判断。
 reg raccept,iaccept;
 always @(posedge clk)if(rst_n)begin
  raccept=rv && raw_ready;iaccept=iv && isp_ready;
  if(raw_service && rq>0)begin
   if(!raw_poison && rmem[rhead]!==rread[7:0])$fatal(1,"RAW_QUEUE_BYTE_MISMATCH");
   rhead=(rhead+1)%8;rq=rq-1;rread=rread+1;
  end
  if(isp_service && iq>0)begin
   if(!isp_poison && imem[ihead]!==iread[7:0])$fatal(1,"ISP_QUEUE_BYTE_MISMATCH");
   ihead=(ihead+1)%8;iq=iq-1;iread=iread+1;
  end
  if(raccept)begin rmem[rtail]=data;rtail=(rtail+1)%8;rq=rq+1;end
  if(iaccept)begin imem[itail]=data;itail=(itail+1)%8;iq=iq+1;end
  if(rq>rpeak)rpeak=rq;if(iq>ipeak)ipeak=iq;
  #2;if(rabort)raw_poison=1;if(iabort)isp_poison=1;
 end
 task tick;begin @(posedge clk);#3;@(negedge clk);end endtask
 task check(input condition,input [511:0] label);
 begin checks=checks+1;if(condition!==1'b1)$fatal(1,"DVP_RAW8_QUEUES_FAIL %0s",label);end endtask
 task frame(input integer pause_start,input integer pause_end);
 begin
  raw_poison=0;isp_poison=0;rread=0;iread=0;start=1;tick;start=0;
  for(integer i=0;i<32;i=i+1)begin
   valid=1;data=i;x=i;raw_service=!(i>=pause_start && i<pause_end);isp_service=1;tick;
  end
  valid=0;finish=1;tick;finish=0;
 end endtask
 initial begin
  repeat(5)tick;rst_n=1;tick;
  frame(8,12);check(rlegal && ilegal && !raw_poison && !isp_poison,"four-cycle pause covered by eight entries");
  raw_service=1;repeat(12)tick;check(rq==0 && iq==0 && rread==32 && iread==32,"complete queue drains exactly once");
  frame(4,20);check(!rlegal && ilegal && raw_poison && !isp_poison,"overbound RAW service invalidates only RAW");
  raw_service=1;repeat(20)tick;check(rq==0 && iq==0,"poisoned old RAW data drained before next admission");
  frame(8,12);check(rlegal && ilegal && !raw_poison,"new frame resynchronizes after drain");
  repeat(12)tick;check(rread==32 && iread==32 && rpeak==8 && ipeak<=2,"finite depth and peak watermark");
  $display("DVP_RAW8_QUEUES_PASS checks=%d raw_peak=%d isp_peak=%d depth=8",checks,rpeak,ipeak);$finish;
 end
 initial begin #100000;$fatal(1,"DVP_RAW8_QUEUES_TIMEOUT");end
endmodule
