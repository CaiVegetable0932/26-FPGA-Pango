`timescale 1ns/1ps
// 用途：1920x1080 RAW8 全尺寸逐字节核对，验证行内II=1及真实结束边界之前没有legal。
// 100MHz是合成PCLK测试条件，不是本板实测输入或外部setup/hold签核。
module tb_dvp_raw8_full;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg [7:0] data=0;reg href=0,vsync=1,cfg=0,enable=0;
 wire pv,fe,legal;wire [15:0] pixel,x,y,errors,lines;wire [31:0] bytes,pixels,ticks;
 wire [159:0] tag;
 integer count=0,cycles=0,last_cycle=0;
 dvp_frame_receiver #(.WARMUP_FRAMES(0),.FRAME_TIMEOUT(4000000),.LINE_TIMEOUT(3000)) dut(
 .pclk(clk),.rst_n(rst_n),.dvp_data(data),.href(href),.vsync(vsync),.capture_enable(enable),
 .pipeline_drained(1'b1),.cfg_valid(cfg),.cfg_width(16'd1920),.cfg_height(16'd1080),.cfg_bayer(3'd1),
 .cfg_version(32'd3),.cfg_entity(32'd55),.token_valid(1'b1),.next_frame_tag(160'h123456789abcdef),
 .input_overflow(1'b0),.pixel_valid(pv),.pixel_data(pixel),.pixel_x(x),.pixel_y(y),.pixel_tag(tag),
 .frame_end(fe),.frame_legal(legal),.frame_errors(errors),.last_frame_bytes(bytes),.last_frame_pixels(pixels),
 .last_frame_ticks(ticks),.last_frame_lines(lines));
 always @(posedge clk)begin #2;cycles=cycles+1;
  if(pv)begin
   if(pixel!==((x+y*1920+23)&255) || tag!==160'h123456789abcdef)$fatal(1,"RAW_FULL_DATA_FAIL");
   if(x!=(count%1920) || y!=(count/1920))$fatal(1,"RAW_FULL_COORDINATE_FAIL");
   if(x!=0 && cycles-last_cycle!=1)$fatal(1,"RAW_FULL_II_FAIL");
   count=count+1;last_cycle=cycles;
  end
  if(legal && !fe)$fatal(1,"RAW_FULL_EARLY_PUBLICATION");
 end
 task tick(input v,input h,input [7:0] d);
 begin @(negedge clk);vsync=v;href=h;data=d;@(posedge clk);#3;end endtask
 initial begin
  repeat(5)tick(1,0,0);rst_n=1;cfg=1;tick(1,0,0);cfg=0;enable=1;
  repeat(4)tick(1,0,0);repeat(4)tick(0,0,0);
  for(integer yy=0;yy<1080;yy=yy+1)begin
   for(integer xx=0;xx<1920;xx=xx+1)tick(0,1,(xx+yy*1920+23)&255);
   repeat(8)tick(0,0,0);
  end
  if(legal)$fatal(1,"RAW_FULL_LAST_PIXEL_IS_NOT_SEAL");
  tick(1,0,0);tick(1,0,0);
  if(!fe || !legal || errors!=0 || count!=2073600 || pixels!=2073600 || bytes!=2073600 || lines!=1080)
   $fatal(1,"RAW_FULL_SEAL_FAIL count=%d pixel=%d bytes=%d lines=%d",count,pixels,bytes,lines);
  $display("DVP_RAW8_FULL_PASS bytes=%d active_frame_ticks=%d peak_II=1 simulated_clock_hz=100000000",bytes,ticks);
  $finish;
 end
 initial begin #50000000;$fatal(1,"DVP_RAW8_FULL_TIMEOUT");end
endmodule
