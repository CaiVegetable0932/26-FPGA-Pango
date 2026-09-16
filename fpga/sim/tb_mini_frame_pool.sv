`timescale 1ns/1ps
// Purpose: adversarial transaction-level test of frame ownership, publication and
// asynchronous request handshakes. DMA payload/FIFO latency is a separate test.
module tb_mini_frame_pool;
 reg clk=0,reset_n=0,camera_req=0,display_req=0;
 wire camera_ack,display_ack,wr_req,rd_req;
 reg wr_ack=0,rd_ack=0,wr_finish=0;
 wire [1:0] wi,ri;wire dv;wire [31:0] completed,abandoned;
 integer checks=0,n;
 reg [1:0] locked,previous;
 always #4 clk=~clk;
 mini_frame_pool dut(clk,reset_n,camera_req,display_req,wr_ack,rd_ack,wr_finish,
  camera_ack,display_ack,wr_req,rd_req,wi,ri,dv,completed,abandoned);
 task tick;begin @(posedge clk);#1;end endtask
 task check(input reg ok,input [255:0] label_text);
 begin checks=checks+1;if(ok!==1'b1)begin $display("FRAME_POOL_FAIL %s",label_text);$fatal(1);end end endtask
 // Purpose: model downstream four-phase ACK after its burst boundary.
 always @(posedge clk) begin
  if(!reset_n)begin wr_ack<=0;rd_ack<=0;end
  else begin wr_ack<=wr_req;rd_ack<=rd_req;end
 end
 task capture_start;
 begin #3;camera_req=1;wait(camera_ack);#3;camera_req=0;wait(!camera_ack);repeat(3)tick;end endtask
 task capture_finish;
 begin @(negedge clk);wr_finish=1;tick;@(negedge clk);wr_finish=0;tick;end endtask
 task display_start;
 begin #2;display_req=1;wait(display_ack);#3;display_req=0;wait(!display_ack);repeat(3)tick;end endtask
 initial begin
  repeat(4)tick;reset_n=1;repeat(4)tick;
  display_start;check(!dv&&!rd_req,"no unwritten startup reads");
  capture_start;previous=wi;check(!dv,"no publication on allocation");
  capture_finish;check(completed==1,"completion counted");
  display_start;check(dv && ri==previous,"display completed slot");locked=ri;
  // Purpose: repeated camera frames cannot overwrite a slow/frozen display slot.
  for(n=0;n<100;n=n+1)begin
   capture_start;check(wi!=locked,"display slot protected");
   previous=wi;capture_finish;
   if(n%3==0)begin display_start;check(ri==previous,"latest completed selected");locked=ri;end
  end
  // Purpose: preempt an incomplete capture, never publish it.
  capture_start;previous=wi;capture_start;
  check(wi!=previous && wi!=locked,"abandoned slot not reused before ack");
  check(abandoned==1,"abandoned frame counted");previous=wi;
  display_start;check(ri!=previous,"unfinished capture not displayed");
  capture_finish;display_start;check(ri==previous,"replacement publishes on finish");
  // Purpose: simultaneous requests stay non-overlapping.
  fork capture_start;display_start;join
  check(wi!=ri,"simultaneous ownership");capture_finish;
  reset_n=0;tick;check(!dv && !camera_ack && !display_ack,"reset invalidates frame pool");
  $display("FRAME_POOL_PASS checks=%0d completed_before_reset=103",checks);$finish;
 end
 initial begin #1000000;$display("FRAME_POOL_TIMEOUT");$fatal(1);end
endmodule
