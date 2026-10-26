`timescale 1ns/1ps
// 用途：新完整性接收器的RGB565诊断字节序/奇字节短行；不替代旧诊断集成回归。
module tb_dvp_rgb565_receiver;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg [7:0] data=0;reg href=0,vsync=1,cfg=0,enable=0;
 wire valid,done,legal;wire [15:0] pixel,x,y,errors;integer count=0;
 dvp_frame_receiver #(.FORMAT(2),.MAX_WIDTH(4),.MAX_HEIGHT(4),.WARMUP_FRAMES(0),.FRAME_TIMEOUT(200),.LINE_TIMEOUT(50)) dut(
 .pclk(clk),.rst_n(rst_n),.dvp_data(data),.href(href),.vsync(vsync),.capture_enable(enable),
 .pipeline_drained(1'b1),.cfg_valid(cfg),.cfg_width(16'd2),.cfg_height(16'd2),.cfg_bayer(3'd0),
 .cfg_version(32'd1),.cfg_entity(32'd2),.token_valid(1'b1),.next_frame_tag(160'h42),.input_overflow(1'b0),
 .pixel_valid(valid),.pixel_data(pixel),.pixel_x(x),.pixel_y(y),.frame_end(done),.frame_legal(legal),.frame_errors(errors));
 always @(posedge clk)begin #2;if(valid)begin
  if(pixel!==(16'h1200+x+y*2))$fatal(1,"RGB565_BYTE_ORDER_FAIL %h",pixel);count=count+1;
 end end
 task tick(input v,input h,input [7:0] d);
 begin @(negedge clk);vsync=v;href=h;data=d;@(posedge clk);#3;end endtask
 task start_frame;begin count=0;repeat(4)tick(1,0,0);repeat(4)tick(0,0,0);end endtask
 task rows(input broken);
 begin for(integer yy=0;yy<2;yy=yy+1)begin
  for(integer xx=0;xx<2;xx=xx+1)begin
   tick(0,1,8'h12);if(!(broken && yy==0 && xx==1))tick(0,1,xx+yy*2);
  end
  repeat(4)tick(0,0,0);
 end end endtask
 initial begin
  repeat(5)tick(1,0,0);rst_n=1;cfg=1;tick(1,0,0);cfg=0;enable=1;
  start_frame;rows(0);tick(1,0,0);tick(1,0,0);
  if(!done || !legal || count!=4)$fatal(1,"RGB565_COMPLETE_FAIL");
  start_frame;rows(1);tick(1,0,0);tick(1,0,0);
  if(!done || legal || !(errors&1))$fatal(1,"RGB565_ODD_ROW_FAIL");
  start_frame;rows(0);tick(1,0,0);tick(1,0,0);
  if(!legal || count!=4)$fatal(1,"RGB565_REALIGN_FAIL");
  $display("DVP_RGB565_RECEIVER_PASS");$finish;
 end
 initial begin #100000;$fatal(1,"DVP_RGB565_RECEIVER_TIMEOUT");end
endmodule
