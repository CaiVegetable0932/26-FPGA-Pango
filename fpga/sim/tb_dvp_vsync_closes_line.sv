`timescale 1ns/1ps
// Purpose: reproduce raw full-frame detection with no admitted pixels when
// VSYNC closes active video before HREF falls. No blanking byte is valid data.
module tb_dvp_vsync_closes_line #(parameter WIDTH=4,HEIGHT=2,HREF_BLANK_CYCLES=1);
 reg clk=0,rst_n=0,v=1,h=0;
 always #5 clk=~clk;
 wire wr;wire [3:0] seen;
 integer frame,row,b,writes=0;
 camera_data #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.WARMUP_FRAMES(10)) dut(
 .clk(clk),.rst_n(rst_n),.vsync(v),.href(h),.din(8'ha5),
 .cfg_done(1'b1),.ddr_init(1'b1),.pixel_data(),.wf_wr_en(wr),.sop(),.eop(),.vs(),.hs());
 mini_dvp_observe #(.WIDTH_BYTES(WIDTH*2),.HEIGHT(HEIGHT)) observer(clk,rst_n,v,h,seen);
 task tick(input bit nv,input bit nh);
 begin @(negedge clk);v=nv;h=nh;@(posedge clk);#1;if(wr)writes=writes+1;end
 endtask
 initial begin
  repeat(5)tick(1,0);rst_n=1;repeat(5)tick(1,0);
  for(frame=0;frame<12;frame=frame+1) begin
   repeat(4)tick(1,0);tick(0,0);
   for(row=0;row<HEIGHT;row=row+1) begin
    repeat(WIDTH*2)tick(0,1);
    if(row<HEIGHT-1)repeat(3)tick(0,0);
   end
   // HREF remains high for the first blanking cycle; VSYNC is authoritative.
   repeat(HREF_BLANK_CYCLES)tick(1,1);repeat(3)tick(1,0);
  end
  $display("VSYNC_CLOSE_RESULT raw=%b warmup=%0d pixels=%0d",seen,dut.eop_cnt,writes);
  if(seen!=15 || dut.eop_cnt!=10 || writes!=2*WIDTH*HEIGHT)$fatal(1,"VSYNC_CLOSE_FAIL");
  $display("DVP_VSYNC_CLOSE_PASS");$finish;
 end
 initial begin #1000000000;$fatal(1,"VSYNC_CLOSE_TIMEOUT");end
endmodule
