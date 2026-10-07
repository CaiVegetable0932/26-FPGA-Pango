`timescale 1ns/1ps
// Purpose: full gray processing against a delayed native-DDR model. Verify
// identity, subpixel mapping, edge masks, source cache invalidation, shadow
// changes during a frame, row padding and ordered result fence publication.
module tb_geometry_pipeline;
 reg clk=0,rst=0,start=0,cmd_valid=0,display_original=0;always #4 clk=~clk;
 wire frame_original;wire [447:0] active_words;wire [1:0] active_model;wire active_enhance;
 reg [7:0] cmd=0;reg [255:0] payload=0;wire [7:0] code;wire [95:0] reply;
 reg [63:0] frame_id=100;
 wire busy,done,good,fault;wire [27:0] awaddr,read_addr;wire [3:0] awlen;
 wire awvalid,read_req;wire [4:0] read_len;wire [255:0] wdata;wire [31:0] wstrb;
 reg awready=0,wready=0,wlast=0,read_ready=0,read_valid=0,read_done=0;
 reg [255:0] read_data=0;
 wire [31:0] version,frame_version,frame_cycles,hits,misses;wire [63:0] applied;
 geometry_gray_processor #(.WIDTH(32),.HEIGHT(8),.STRIDE(64)) dut(
  // Purpose: observe the exact configuration latched for each output frame.
  .clk(clk),.rst_n(rst),.start(start),.display_original(display_original),
  .frame_original(frame_original),.active_words_out(active_words),
  .active_model_out(active_model),.active_enhance_out(active_enhance),
  .source_base(28'b0),.result_base(28'h4000000),
  .source_id(frame_id),.epoch(64'd123),.context_valid(1'b1),.session_id(32'd1),
  .cmd_valid(cmd_valid),.cmd(cmd),.payload(payload),.code(code),.reply(reply),
  .busy(busy),.done(done),.good(good),.fault(fault),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),.wready(wready),
  .wlast(wlast),.wid(4'b0),.wdata(wdata),.wstrb(wstrb),
  .read_req(read_req),.read_addr(read_addr),.read_len(read_len),.read_ready(read_ready),
  .read_valid(read_valid),.read_done(read_done),.read_data(read_data),
  .active_version(version),.frame_version(frame_version),.frame_cycles(frame_cycles),
  .cache_hits(hits),.cache_misses(misses),.applied_frame_id(applied));
 reg [255:0] source[0:15],result[0:15],mask;
 reg writing=0,reading=0,return_done=0;integer wc=0,rc=0,cyc=0,fences=0;
 reg [27:0] wa,ra;
 // Purpose: no ideal write-through shortcut. AW, W, read data and done are
 // independently delayed; the fence reads the stored final mask word.
 always @(posedge clk)if(rst)begin
  cyc=cyc+1;
  if(fault)$fatal(1,"GEOMETRY_PIPELINE_FAIL datapath fault");
  if(awvalid && awready)begin
   if(writing || awlen!=0)$fatal(1,"GEOMETRY_PIPELINE_FAIL AW");
   writing=1;wa=awaddr<<2;wc=3+cyc%5;
  end
  if(wready)begin
   if(!writing || !wlast || wstrb!=32'hffffffff)$fatal(1,"GEOMETRY_PIPELINE_FAIL W");
   if(wa>=28'h4000000 && wa<28'h4000200)begin
    if(wa[5])$fatal(1,"GEOMETRY_PIPELINE_FAIL padding written");
    result[(wa-28'h4000000)>>5]=wdata;
   end else if(wa==28'h4280000)mask=wdata;
   else $fatal(1,"GEOMETRY_PIPELINE_FAIL write address %h",wa);
   writing=0;
  end
  if(read_req && read_ready)begin
   if(reading || read_len!=1 || read_addr[4:0]!=0)$fatal(1,"GEOMETRY_PIPELINE_FAIL read");
   reading=1;ra=read_addr;rc=4+cyc%7;
   if(ra==28'h4280000)fences=fences+1;
  end
 end
 always @(negedge clk)begin
  awready=rst && !writing && cyc%3!=0;wready=0;wlast=0;
  read_ready=rst && !reading && !return_done && cyc%5!=0;
  read_valid=0;read_done=return_done;return_done=0;
  if(writing)begin if(wc>0)wc=wc-1;else begin wready=1;wlast=1;end end
  if(reading)begin
   if(rc>0)rc=rc-1;
   else begin
    read_valid=1;reading=0;return_done=1;
    if(ra<512)read_data=source[ra>>5];
    else if(ra==28'h4280000)read_data=mask;
    else $fatal(1,"GEOMETRY_PIPELINE_FAIL source bounds %h",ra);
   end
  end
 end
 task command;
  input [7:0] opcode;input [255:0] data;input [7:0] expected;
  begin
   @(negedge clk);cmd=opcode;payload=data;#1;
   if(code!==expected)$fatal(1,"GEOMETRY_PIPELINE_FAIL command %h code %d expected %d",opcode,code,expected);
   cmd_valid=1;@(negedge clk);cmd_valid=0;
  end
 endtask
 integer i,x,y,seed=0,shiftx=0,shifty=0,got,wanted,maskwant;
 reg [31:0] words[0:13];reg [255:0] request;
 task load_profile;
  input [31:0] ver;input signed [31:0] translation_x,translation_y;
  begin
   request=0;request[127:96]=ver;request[135:128]=1;
   request[159:144]=32;request[175:160]=8;command(8'h30,request,0);
   for(i=0;i<14;i=i+1)begin
    request=0;request[127:96]=ver;request[159:128]=i;
    request[191:160]=i==2?translation_x:i==5?translation_y:words[i];
    command(8'h31,request,0);
   end
   request=0;request[127:96]=ver;command(8'h32,request,0);
  end
 endtask
 function integer raw;
  input integer xx,yy;
  begin raw=(xx*7+yy*19+seed)%256;end
 endfunction
 function integer gray;
  input integer xx,yy;
  integer xl,yt;
  begin xl=xx==0?0:xx-1;yt=yy==0?0:yy-1;
   gray=(raw(xl,yt)+raw(xx,yt)+raw(xl,yy)+raw(xx,yy)+2)/4;
  end
 endfunction
 task compare_frame;
  integer xx,yy,qx,qy,ix,iy,jx,jy,fx,fy,a,b,c,d;
  reg [63:0] weighted;
  begin
   for(yy=0;yy<8;yy=yy+1)for(xx=0;xx<32;xx=xx+1)begin
    qx=xx*4096+shiftx;qy=yy*4096+shifty;
    maskwant=qx>=0 && qy>=0 && qx<=31*4096 && qy<=7*4096;
    wanted=0;
    if(maskwant)begin
     ix=qx/4096;iy=qy/4096;jx=ix==31?ix:ix+1;jy=iy==7?iy:iy+1;
     fx=qx%4096;fy=qy%4096;a=gray(ix,iy);b=gray(jx,iy);c=gray(ix,jy);d=gray(jx,jy);
     weighted=64'(4096-fy)*((4096-fx)*a+fx*b)+64'(fy)*((4096-fx)*c+fx*d)+8388608;
     wanted=weighted>>24;
    end
    got=result[yy*2][xx*8+:8];
    if(got!=wanted || mask[yy*32+xx]!==maskwant[0])
     $fatal(1,"GEOMETRY_PIPELINE_FAIL pixel %0d %0d got %0d expected %0d mask %0b",xx,yy,got,wanted,mask[yy*32+xx]);
   end
  end
 endtask
 task fill_source;
  begin
   for(y=0;y<8;y=y+1)for(x=0;x<32;x=x+1)source[y*2][x*8+:8]=raw(x,y);
   for(y=0;y<16;y=y+1)result[y]='hdead;
  end
 endtask
 initial begin
  for(i=0;i<14;i=i+1)words[i]=0;
  words[0]=4194304;words[4]=4194304;words[10]=1048576;words[11]=1048576;
  fill_source();repeat(4)@(negedge clk);rst=1;
  load_profile(1,0,0);wait(dut.u_config.pending);
  @(negedge clk);start=1;@(negedge clk);start=0;
  // Stage a subpixel profile while processing: the entire first frame must
  // remain identity. Its activation is delayed until the following start.
  wait(busy);load_profile(2,2097152,1048576);
  wait(done);@(negedge clk);
  if(!good || version!=1 || frame_version!=1 || fences!=1)$fatal(1,"GEOMETRY_PIPELINE_FAIL first commit");
  compare_frame();wait(!busy);wait(dut.u_config.pending);
  seed=41;fill_source();frame_id=101;shiftx=2048;shifty=1024;
  @(negedge clk);start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(!good || version!=2 || frame_version!=2 || applied!=101 || fences!=2)
   $fatal(1,"GEOMETRY_PIPELINE_FAIL second commit");
  compare_frame();
  if(hits==0 || misses==0)$fatal(1,"GEOMETRY_PIPELINE_FAIL cache coverage");
  // Purpose: original/corrected selection bypasses geometry only. A control
  // change while pixels are in flight must not alter that frame or its ISP.
  wait(!busy);display_original=1;seed=91;fill_source();frame_id=102;shiftx=0;shifty=0;
  @(negedge clk);start=1;@(negedge clk);start=0;
  repeat(30)@(negedge clk);display_original=0;
  wait(done);@(negedge clk);
  if(!good || !frame_original || frame_version!=2 || fences!=3 || active_enhance || active_model!=1)
   $fatal(1,"GEOMETRY_PIPELINE_FAIL original mode atomicity/ISP");
  compare_frame();
  wait(!busy);seed=123;fill_source();frame_id=103;shiftx=2048;shifty=1024;
  @(negedge clk);start=1;@(negedge clk);start=0;
  repeat(30)@(negedge clk);display_original=1;
  wait(done);@(negedge clk);
  if(!good || frame_original || frame_version!=2 || fences!=4)
   $fatal(1,"GEOMETRY_PIPELINE_FAIL corrected mode atomicity");
  compare_frame();
  $display("GEOMETRY_PIPELINE_PASS frames=4 pixels=1024 cycles=%0d cache_hits=%0d cache_misses=%0d",frame_cycles,hits,misses);$finish;
 end
 initial begin #6000000;$fatal(1,"GEOMETRY_PIPELINE_TIMEOUT");end
endmodule
