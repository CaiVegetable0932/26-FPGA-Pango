`timescale 1ns/1ps
// 用途：逐字节/坐标/tag核验RAW8，覆盖短长行、缺多行、坏边界、超时、溢出、令牌与配置切换。
module tb_dvp_frame_receiver;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg [7:0] data=0;reg href=0,vsync=1,enable=0,drained=1,cfg=0,token=1,overflow=0;
 reg [15:0] width=4,height=3;reg [2:0] bayer=1;
 reg [31:0] version=7,entity=9;reg [159:0] tag=160'h1234;
 wire cfgready,cfgok,cfgbad,pv,sof,eol,last,fs,fa,abort,fe,legal;
 wire [15:0] pd,x,y,errors,lastlines;wire [1:0] phase;wire [159:0] ptag,ftag;
 wire [31:0] fver,fentity,sources,valids,bads,warms,lastbytes,lastpixels,lastticks;
 wire [63:0] first_tick,last_tick;
 integer pixels=0,ends=0,aborts=0,checks=0;reg lastlegal;reg [15:0] lasterr;
 reg [159:0] expected_tag;
 dvp_frame_receiver #(.MAX_WIDTH(8),.MAX_HEIGHT(4),.WARMUP_FRAMES(0),.FRAME_TIMEOUT(160),.LINE_TIMEOUT(50)) dut(
  .pclk(clk),.rst_n(rst_n),.dvp_data(data),.href(href),.vsync(vsync),.capture_enable(enable),
  .pipeline_drained(drained),.cfg_valid(cfg),.cfg_ready(cfgready),.cfg_width(width),.cfg_height(height),
  .cfg_bayer(bayer),.cfg_version(version),.cfg_entity(entity),.cfg_accepted(cfgok),.cfg_rejected(cfgbad),
  .token_valid(token),.next_frame_tag(tag),.input_overflow(overflow),.pixel_valid(pv),.pixel_data(pd),
  .pixel_x(x),.pixel_y(y),.pixel_sof(sof),.pixel_eol(eol),.pixel_last(last),.pixel_phase(phase),.pixel_tag(ptag),
  .frame_start(fs),.frame_admitted(fa),.frame_abort(abort),.frame_end(fe),.frame_legal(legal),
  .frame_errors(errors),.frame_tag(ftag),.frame_version(fver),.frame_entity(fentity),
  .capture_first(first_tick),.capture_last(last_tick),.source_frames(sources),.valid_frames(valids),
  .error_frames(bads),.warmup_frames(warms),.last_frame_bytes(lastbytes),.last_frame_pixels(lastpixels),
  .last_frame_ticks(lastticks),.last_frame_lines(lastlines));
 task check(input condition,input [511:0] label);
  begin checks=checks+1;if(condition!==1'b1)$fatal(1,"DVP_FRAME_RECEIVER_FAIL %0s",label);end
 endtask
 // 只根据输出坐标与独立公式核对数据；输入tag/版本中途改变也不能污染已锁存实体。
 always @(posedge clk)begin #2;
  if(pv)begin
   check(pd==((x+y*4+8'h20)&255),"RAW8 exact byte, no RGB packing");
   check(x<4 && y<3 && ptag==expected_tag && fver==7 && fentity==9,"coordinate/tag/version alignment");
   check(phase==({y[0],x[0]}^(bayer-1)),"all Bayer parity codes");
   check(sof==(x==0 && y==0) && eol==(x==3) && last==(x==3 && y==2),"markers align with payload");
   pixels=pixels+1;
  end
  if(fe)begin ends=ends+1;lastlegal=legal;lasterr=errors;end
  if(abort)aborts=aborts+1;
 end
 task tick(input v,input h,input [7:0] d);
  begin @(negedge clk);vsync=v;href=h;data=d;@(posedge clk);#3;end
 endtask
 task configure(input [2:0] code);
  begin enable=0;repeat(5)tick(1,0,0);bayer=code;cfg=1;tick(1,0,0);
   check(cfgok,"quiesced config accepted");cfg=0;enable=1;repeat(5)tick(1,0,0);end
 endtask
 task begin_frame;
  begin pixels=0;ends=0;aborts=0;tag=tag+1;expected_tag=tag;
   repeat(4)tick(1,0,0);repeat(4)tick(0,0,0);end
 endtask
 task row(input integer yy,input integer count);
  begin for(integer xx=0;xx<count;xx=xx+1)tick(0,1,(xx+yy*4+8'h20)&255);
   repeat(4)tick(0,0,0);end
 endtask
 task end_frame;
  begin repeat(5)tick(1,0,0);check(ends==1,"exactly one final seal event");end
 endtask
 task good_frame;
  begin begin_frame;for(integer yy=0;yy<3;yy=yy+1)row(yy,4);end_frame;
   check(lastlegal && lasterr==0 && pixels==12 && lastbytes==12 && lastlines==3,"complete RAW8 frame");end
 endtask
 initial begin
  repeat(5)tick(1,0,0);rst_n=1;
  for(integer code=1;code<=4;code=code+1)begin configure(code);good_frame;end
  begin_frame;row(0,3);row(1,4);row(2,4);end_frame;
  check(!lastlegal && (lasterr&1) && aborts==1,"short row invalidates whole frame once");
  good_frame;
  begin_frame;row(0,5);row(1,4);row(2,4);end_frame;
  check(!lastlegal && (lasterr&2) && pixels==4,"long row cannot wrap into second row");
  begin_frame;row(0,4);row(1,4);end_frame;check(!lastlegal && (lasterr&4),"missing row rejected");
  begin_frame;row(0,4);row(1,4);row(2,4);row(3,4);end_frame;
  check(!lastlegal && (lasterr&8) && pixels==12,"extra row prevents tentative EOF publishing");
  begin_frame;row(0,4);overflow=1;tick(0,0,0);overflow=0;row(1,4);row(2,4);end_frame;
  check(!lastlegal && (lasterr&64) && aborts==1,"input FIFO overflow poisons frame");
  good_frame;
  begin_frame;row(0,4);enable=0;repeat(5)tick(0,0,0);
  check(ends==1 && !lastlegal && (lasterr&128),"readiness loss terminates partial frame");
  enable=1;good_frame;
  token=0;begin_frame;row(0,4);row(1,4);row(2,4);end_frame;
  check(!lastlegal && (lasterr&512) && pixels==0,"no allocation token cannot emit pixels");token=1;
  begin_frame;row(0,4);cfg=1;tick(0,0,0);check(cfgbad,"busy mode change rejected");cfg=0;
  tag=160'hdead;version=99;entity=99;row(1,4);row(2,4);end_frame;
  check(lastlegal && fver==7 && fentity==9 && ftag==expected_tag,"midframe inputs cannot relabel source");
  version=7;entity=9;
  begin_frame;row(0,4);repeat(180)tick(0,0,0);
  check(ends==1 && !lastlegal && (lasterr&32),"missing VSYNC has bounded timeout");
  good_frame;
  begin_frame;for(integer i=0;i<60;i=i+1)tick(0,1,i+8'h20);check(ends==1 && (lasterr&32),"stuck HREF bounded timeout");
  repeat(5)tick(1,0,0);good_frame;
  // 起点同拍必须保留首字节并与新tag一起输出，不能靠接口假设丢首像素。
  pixels=0;ends=0;aborts=0;tag=tag+1;expected_tag=tag;
  tick(0,1,8'h20);tick(0,1,8'h21);tick(0,1,8'h22);tick(0,1,8'h23);
  repeat(4)tick(0,0,0);row(1,4);row(2,4);end_frame;
  check(lastlegal && pixels==12,"coincident VSYNC/HREF first byte captured");
  begin_frame;row(0,4);repeat(3)tick(1,1,8'h20);
  check(ends==1 && !lastlegal && (lasterr&16),"HREF within VSYNC blank marks boundary fault");
  enable=0;repeat(5)tick(1,0,0);width=0;cfg=1;tick(1,0,0);check(cfgbad,"zero width config rejected");cfg=0;width=4;
  $display("DVP_FRAME_RECEIVER_PASS checks=%0d sources=%0d valid=%0d errors=%0d",checks,sources,valids,bads);$finish;
 end
 initial begin #1000000;$fatal(1,"DVP_FRAME_RECEIVER_TIMEOUT");end
endmodule
