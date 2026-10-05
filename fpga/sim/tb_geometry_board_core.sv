`timescale 1ns/1ps
// Purpose: full 1080p DVP -> native FIFOs/HMIC leases -> nonidentity gray warp
// -> result publication -> HDMI, while Ethernet also drains camera frames.
// The delayed memory is a protocol model, NOT DDR PHY or hardware verification.
module tb_geometry_board_core;
 reg mc=0,cc=0,pc=0,rst=0,vsync=1,href=0;reg [7:0] camera=0;
 always #4 mc=~mc;always #6 cc=~cc;always #6.734 pc=~pc;
 GTP_GRS GRS_INST(.GRS_N(rst));
 reg cv=0;reg [7:0] cmd=0;reg [255:0] payload=0;wire [7:0] code;wire [95:0] reply;
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,arid;
 wire awvalid,arvalid;reg awready=0,arready=0,wready=0,wlast=0,rvalid=0,rlast=0;
 reg [3:0] rid=0;reg [255:0] rdata=0;wire [255:0] wdata;wire [31:0] wstrb;
 wire [23:0] rgb;wire hs,vs,de,en,er,fault;wire [7:0] txd;wire [31:0] published,underflows;
 raw8_geometry_core #(.WARMUP_FRAMES(0)) dut(.mem_clk(mc),.mem_reset_n(rst),
  .cam_clk(cc),.cam_reset_n(rst),.pixel_clk(pc),.pixel_reset_n(rst),.configured(1'b1),
  .vsync(vsync),.href(href),.camera_data(camera),.commissioned(1'b1),.network_enable(1'b1),
  .epoch(64'd123),.src_mac(48'h020000000001),.dst_mac(48'h020000001001),
  .src_ip(32'hc0000201),.dst_ip(32'hc6336402),.src_port(16'd50001),.dst_port(16'd50000),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.arid(arid),
  .awvalid(awvalid),.arvalid(arvalid),.awready(awready),.arready(arready),
  .wready(wready),.wlast(wlast),.wid(4'd0),.rid(rid),.rvalid(rvalid),.rlast(rlast),.rdata(rdata),
  .wdata(wdata),.wstrb(wstrb),.rgb(rgb),.hs(hs),.vs(vs),.de(de),
  .gmii_data(txd),.gmii_en(en),.gmii_error(er),.fault(fault),.published(published),.underflows(underflows),
  .geo_cmd_valid(cv),.geo_cmd(cmd),.geo_payload(payload),.geo_code(code),.geo_reply(reply),
  .mcu_context_valid(1'b1),.mcu_session_id(32'd1),.env_valid(1'b0),.env_measurement_valid(2'b0),
  .env_angle_mdeg(32'd0),.env_event_seq(32'd0),.env_board_time_us(64'd0));
 reg [255:0] ram[0:917503];
 integer cycle=0,wi=0,ri=0,waitw=0,waitr=0,beats=0,read_count=0,writes=0;
 integer raw_fences=0,geo_fences=0,net_frames=0,results=0,display_pixels=0;
 // Purpose: latch latency of the actually completed first result, rather than
 // printing a live counter that may already describe the following frame.
 integer first_result_cycles=0,first_cache_hits=0,first_cache_misses=0;
 reg writing=0,reading=0;reg [3:0] owner;
 // Purpose: preserve native column units/RID ordering and forbid writes to
 // leased RAW sources or HDMI result slots; there is no native RREADY port.
 always @(posedge mc)if(rst)begin
  cycle=cycle+1;
  if(fault || er)$fatal(1,"GEOMETRY_BOARD_FAIL core fault detail=%h geo=%b arb=%b",dut.fault_detail,dut.geo_fault,dut.arb_fault);
  if(dut.geo_done && dut.geo_good)begin
   if(results==0)begin first_result_cycles=dut.geo_cycles;first_cache_hits=dut.geo_hits;first_cache_misses=dut.geo_misses;end
   results=results+1;
  end
  if(dut.net_done)net_frames=net_frames+1;
  if(awvalid && awready)begin
   if(writing || awlen!=0 || awaddr[2:0]!=0)$fatal(1,"GEOMETRY_BOARD_FAIL AW");
   wi=(awaddr-28'hc00000)>>3;
   if(wi<0 || wi>=917504 || (wi>=393216 && wi<524288))$fatal(1,"GEOMETRY_BOARD_FAIL write map");
   if(wi<393216 && ((dut.h_locked && wi/131072==dut.h_slot) ||
      (dut.n_locked && wi/131072==dut.n_slot)))$fatal(1,"GEOMETRY_BOARD_FAIL RAW overwrite");
   if(wi>=524288 && dut.result_hdmi_locked && (wi-524288)/131072==dut.result_hdmi_slot)
    $fatal(1,"GEOMETRY_BOARD_FAIL HDMI result overwrite");
   writing=1;waitw=2+cycle%7;
  end
  if(wready)begin
   if(!writing || !wlast || wstrb!=32'hffffffff)$fatal(1,"GEOMETRY_BOARD_FAIL W");
   ram[wi]=wdata;writing=0;writes=writes+1;
  end
  if(arvalid && arready)begin
   if(reading || araddr[2:0]!=0 || araddr[9:0]+(arlen+1)*8>1024)$fatal(1,"GEOMETRY_BOARD_FAIL AR");
   ri=(araddr-28'hc00000)>>3;beats=arlen+1;read_count=0;owner=arid;
   if(ri<0 || ri+beats>917504)$fatal(1,"GEOMETRY_BOARD_FAIL read map");
   reading=1;waitr=2+cycle%13;
   if(arid==2)raw_fences=raw_fences+1;
   if(arid==3 && ri>=524288)geo_fences=geo_fences+1;
  end
  if(rvalid)begin
   if(!reading || rid!=owner || rlast!=(read_count==beats-1))$fatal(1,"GEOMETRY_BOARD_FAIL RID/last");
   read_count=read_count+1;if(read_count==beats)reading=0;
  end
 end
 always @(negedge mc)begin
  awready=rst && !writing && cycle%5!=0;arready=rst && !reading && cycle%7!=0;
  wready=0;wlast=0;rvalid=0;rlast=0;
  if(writing)begin if(waitw>0)waitw=waitw-1;else begin wready=1;wlast=1;end end
  if(reading)begin
   if(waitr>0)waitr=waitr-1;
   else if(cycle%11!=0)begin rvalid=1;rid=owner;rdata=ram[ri+read_count];rlast=read_count==beats-1;end
  end
 end
 // Purpose: direct admitted-command stimulus isolates board integration;
 // separate UART regression verifies the CRC/session admission layer itself.
 task control(input [7:0] c,input [255:0] p);
  begin @(negedge mc);cmd=c;payload=p;#1;if(code!=0)$fatal(1,"GEOMETRY_BOARD_FAIL config %h/%d",c,code);
   cv=1;@(negedge mc);cv=0;end
 endtask
 integer i,x,y,f,gray;reg [255:0] p;reg [31:0] params[0:13];
 function automatic [7:0] tone(input integer value);
  integer b,d,v;
  begin
   if(value<=24)b=0;else if(value<=80)b=(value-24)*2;
   else if(value<=144)b=112+value-80+((value-80)>>2);
   else if(value==255)b=255;else begin v=value-144;b=192+(v>>1)+(v>>4)+(v>>6);end
   if(value<=8)d=0;else if(value<=16)d=(value-8)*4;
   else if(value<=32)d=32+(value-16)*7;else if(value<=64)d=144+(value-32)*2;
   else if(value<=128)d=208+((value-64)>>1);else if(value<=240)d=240+((value-128)>>4);
   else if(value==255)d=255;else d=247+((value-240)>>1);
   tone=(b+d+1)>>1;
  end
 endfunction
 // Nonidentity half/quarter-pixel translation clips last column/row. Every
 // valid byte is enhanced once, not again by HDMI's legacy Bayer filter.
 always @(posedge pc)if(rst && dut.u_display.active && de)begin
  gray=(display_pixels%1920==1919 || display_pixels/1920==1079)?0:tone(50+dut.result_hdmi_id*31);
  if(rgb!=={3{gray[7:0]}})$fatal(1,"GEOMETRY_BOARD_FAIL pixel %d rgb=%h want=%d",display_pixels,rgb,gray);
  display_pixels=display_pixels+1;
  if(display_pixels==2073600)begin
   if(underflows || published!=2 || net_frames!=2 || raw_fences!=2 || geo_fences<1)
    $fatal(1,"GEOMETRY_BOARD_FAIL counts");
   $display("GEOMETRY_BOARD_PASS source_frames=%d results=%d hdmi_pixels=%d net_frames=%d first_result_cycles=%d cache_hits=%d cache_misses=%d",
      published,results,display_pixels,net_frames,first_result_cycles,first_cache_hits,first_cache_misses);$finish;
  end
 end
 initial begin
  repeat(20)@(negedge cc);rst=1;repeat(100)@(negedge cc);
  // Purpose: exact fixed-point nonidentity rays, safe over full source domain.
  for(i=0;i<14;i=i+1)params[i]=0;
  params[0]=65536;params[2]=32768;params[4]=65536;params[5]=16384;
  params[10]=67108864;params[11]=67108864;
  p=0;p[127:96]=1;p[135:128]=1;p[143:136]=1;p[159:144]=1920;p[175:160]=1080;control('h30,p);
  for(i=0;i<14;i=i+1)begin p=0;p[127:96]=1;p[159:128]=i;p[191:160]=params[i];control('h31,p);end
  p=0;p[127:96]=1;control('h32,p);wait(dut.u_geometry.pending);
  for(f=0;f<2;f=f+1)begin
   for(y=0;y<1086;y=y+1)begin
    for(x=0;x<1920;x=x+1)begin @(negedge cc);vsync=0;href=1;camera=50+f*31;end
    @(negedge cc);href=0;repeat(579)@(negedge cc);
   end
   vsync=1;repeat(40*2500)@(negedge cc);
  end
 end
 initial begin #2500000000;$fatal(1,"GEOMETRY_BOARD_TIMEOUT pub=%d results=%d process=%d pixels=%d",published,results,dut.process_state,display_pixels);end
endmodule
