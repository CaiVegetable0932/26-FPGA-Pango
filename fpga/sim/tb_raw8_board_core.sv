`timescale 1ns/1ps
// Purpose: integrate production capture/leases/native FIFOs/write-fence/read
// arbiter/HDMI/PRAW with a delayed simplified-HMIC memory model. Not a DDR PHY
// or a physical camera model. No constant or ideal shortcut bypasses the core.
module tb_raw8_board_core #(parameter LATE_EPOCH=0);
 reg commissioned=!LATE_EPOCH;
 // Purpose: commission just after DVP start, while START traverses the FIFO.
 // That physical frame must keep its preallocated epoch zero and stay off UDP.
 reg mc=0,cc=0,pc=0,ec=0,rst=0,vsync=1,href=0;reg [7:0] camdata=0;
 initial if(LATE_EPOCH)begin wait(!vsync);@(negedge mc);commissioned=1;end
 always #4 mc=~mc;always #6 cc=~cc;always #6.734 pc=~pc;
 // Independent Ethernet stimulus is slightly slower; packet capture below
 // occurs AFTER the production native-FIFO clock bridge, never before it.
 always #4.01 ec=~ec;
 GTP_GRS GRS_INST(.GRS_N(rst));
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,arid;
 wire awvalid,arvalid;reg awready=0,arready=0,wready=0,wlast=0,rvalid=0,rlast=0;
 reg [3:0] rid=0;wire [255:0] wdata;wire [31:0] wstrb;reg [255:0] rdata=0;
 wire [23:0] rgb;wire hs,vs,de,fault,en,er;wire [7:0] txd;wire [31:0] published,underflows;
 raw8_dual_core #(.WARMUP_FRAMES(0)) dut(.mem_clk(mc),.mem_reset_n(rst),
  .cam_clk(cc),.cam_reset_n(rst),.pixel_clk(pc),.pixel_reset_n(rst),.configured(1'b1),
  .vsync(vsync),.href(href),.camera_data(camdata),.commissioned(commissioned),.network_enable(commissioned),
  .epoch(64'h1020304050607080),.src_mac(48'h020000000001),.dst_mac(48'h020000001001),
  .src_ip(32'hc0000201),.dst_ip(32'hc6336402),.src_port(16'd50001),.dst_port(16'd50000),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.arid(arid),
  .awvalid(awvalid),.arvalid(arvalid),.awready(awready),.arready(arready),
  .wready(wready),.wlast(wlast),.wid(4'b0),.rid(rid),.rvalid(rvalid),.rlast(rlast),
  .rdata(rdata),.wdata(wdata),.wstrb(wstrb),.rgb(rgb),.hs(hs),.vs(vs),.de(de),
  .gmii_data(txd),.gmii_en(en),.gmii_error(er),.fault(fault),.published(published),.underflows(underflows));
 wire [7:0] eth_data;wire eth_en,eth_error,bridge_wr_fault,bridge_rd_fault;
 raw8_gmii_cdc bridge(.wr_clk(mc),.wr_reset_n(rst),.in_data(txd),.in_en(en),.in_error(er),
  .rd_clk(ec),.rd_reset_n(rst),.out_data(eth_data),.out_en(eth_en),.out_error(eth_error),
  .wr_fault(bridge_wr_fault),.rd_fault(bridge_rd_fault));
 reg [255:0] ram[0:393215];
 integer cyc=0,wi=0,ri=0,waitw=0,waitr=0,beats=0,read_count=0,writes=0,fences=0;
 reg writing=0,reading=0;reg [3:0] owner;
 // Purpose: honor native column units (eight columns per UI word), enforce
 // no row crossing and send every read beat without waiting for an RREADY.
 always @(posedge mc)if(rst)begin
  cyc=cyc+1;
  if(fault || er)$fatal(1,"RAW8_BOARD_FAIL core fault writer=%0b arb=%0b pool=%0b",dut.write_fault,dut.arb_fault,dut.pool_fault);
  if(bridge_wr_fault || bridge_rd_fault || eth_error)$fatal(1,"RAW8_BOARD_FAIL GMII bridge fault");
  if(awvalid && awready)begin
   if(writing || awlen!=0 || awaddr[2:0]!=0)$fatal(1,"RAW8_BOARD_FAIL AW protocol");
   wi=(awaddr-28'hc00000)>>3;
   if(wi<0 || wi>=393216 || wi%64>=60)$fatal(1,"RAW8_BOARD_FAIL write map %h",awaddr);
   if((dut.h_locked && wi/131072==dut.h_slot)||(dut.n_locked && wi/131072==dut.n_slot))
    $fatal(1,"RAW8_BOARD_FAIL overwrite reader");
   writing=1;waitw=2+cyc%7;
  end
  if(wready)begin
   if(!writing || !wlast || wstrb!=32'hffffffff)$fatal(1,"RAW8_BOARD_FAIL W protocol");
   ram[wi]=wdata;writing=0;writes=writes+1;
  end
  if(arvalid && arready)begin
   if(reading || araddr[2:0]!=0 || araddr[9:0]+(arlen+1)*8>1024)$fatal(1,"RAW8_BOARD_FAIL AR protocol");
   ri=(araddr-28'hc00000)>>3;beats=arlen+1;read_count=0;owner=arid;
   if(ri<0 || ri+beats>393216)$fatal(1,"RAW8_BOARD_FAIL read map");
   reading=1;waitr=2+cyc%13;
   if(arid==2)fences=fences+1;
  end
  if(rvalid)begin
   if(!reading || rid!=owner || rlast!=(read_count==beats-1))$fatal(1,"RAW8_BOARD_FAIL R protocol");
   read_count=read_count+1;if(read_count==beats)reading=0;
  end
 end
 always @(negedge mc)begin
  awready=rst && !writing && cyc%5!=0;arready=rst && !reading && cyc%7!=0;
  wready=0;wlast=0;rvalid=0;rlast=0;
  if(writing)begin if(waitw>0)waitw=waitw-1;else begin wready=1;wlast=1;end end
  if(reading)begin
   if(waitr>0)waitr=waitr-1;
   else if(cyc%11!=0)begin rvalid=1;rid=owner;rdata=ram[ri+read_count];rlast=read_count==beats-1;end
  end
 end
 integer frame_i,x,y,pixels=0,hdmi_frames=0,net_frames=0,packet_count=0;
 integer hexfile,lenfile,wire_length=0;reg was_en=0;
 reg [63:0] hdmi_id;
 // Purpose: independently predict the hardware display-only correction.
 // UDP byte-exact scoreboard below still checks the unmodified RAW source.
 function automatic [7:0] display_tone(input [7:0] value);
  // Purpose: assert brighter board-level midtones and preserved high codes;
  // the parallel Ethernet checker remains byte-exact to source RAW.
  if(value<=24)display_tone=0;
  else if(value<=80)display_tone=(value-24)*2;
  else if(value<=144)display_tone=112+(value-80)+((value-80)>>2);
  else if(value==255)display_tone=255;
  else display_tone=192+((value-144)>>1)+((value-144)>>4)+((value-144)>>6);
 endfunction
 function automatic [7:0] median3(input [7:0] a,b,c);
  if(a>b)median3=b>c?b:(a>c?c:a);
  else median3=a>c?a:(b>c?c:b);
 endfunction
 reg [7:0] expected_raw,expected_display;
 always @(posedge mc)if(rst && dut.net_done)net_frames=net_frames+1;
 always @(posedge ec)if(rst)begin
  if(eth_en)begin
   if(!was_en)wire_length=0;
   $fwrite(hexfile,"%02x\n",eth_data);wire_length=wire_length+1;
  end else if(was_en)begin $fwrite(lenfile,"%0d\n",wire_length);packet_count=packet_count+1;end
  was_en=eth_en;
 end
 // Verify the selected HDMI slot's identity stays locked across all pixels.
 always @(posedge pc)if(rst && dut.u_display.active && de)begin
  if(pixels==0)hdmi_id=dut.h_id;
  expected_raw=8'((pixels*17+hdmi_id*31+22)&255);
  expected_display=pixels%1920>=4 ? median3(expected_raw,
   8'(((pixels-2)*17+hdmi_id*31+22)&255),
   8'(((pixels-4)*17+hdmi_id*31+22)&255)) : expected_raw;
  if(dut.h_id!=hdmi_id || rgb!=={3{display_tone(expected_display)}})
   $fatal(1,"RAW8_BOARD_FAIL HDMI pixel=%0d fid=%0d rgb=%h",pixels,hdmi_id,rgb);
  pixels=pixels+1;
  if(pixels==2073600)begin pixels=0;hdmi_frames=hdmi_frames+1;end
 end
 initial begin
  hexfile=$fopen(LATE_EPOCH?"late_board_gmii.hex":"board_gmii.hex","w");
  lenfile=$fopen(LATE_EPOCH?"late_board_gmii_lengths.txt":"board_gmii_lengths.txt","w");
  // Purpose: refuse the first lease to model temporary slot exhaustion. The
  // production requester must retry after availability returns, without reset.
  force dut.u_pool.found=0;
  repeat(20)@(negedge cc);rst=1;repeat(100)@(negedge cc);
  // Release of a forced combinational reg does not itself retrigger always @*;
  // explicitly restore availability for one cycle before normal pool evaluation.
  force dut.u_pool.found=1;@(negedge mc);release dut.u_pool.found;
  repeat(100)@(negedge cc);
  for(frame_i=0;frame_i<6;frame_i=frame_i+1)begin
   // Purpose: reproduce all 1086 measured sensor rows. The final six rows
   // remain physically present but must not enter HDMI/UDP frame payloads.
   for(y=0;y<1086;y=y+1)begin
    for(x=0;x<1920;x=x+1)begin
     @(negedge cc);vsync=0;href=1;camdata=((y*1920+x)*17+frame_i*31+22)&255;
    end
    @(negedge cc);href=0;repeat(579)@(negedge cc);
   end
   vsync=1;repeat(40*2500)@(negedge cc);
  end
  wait(net_frames==6-LATE_EPOCH && hdmi_frames>=4 && !en && !dut.mac_busy &&
       packet_count==1482*(6-LATE_EPOCH) && !eth_en);
  if(published!=6 || underflows!=0 || writes!=388800 || fences!=6 || packet_count!=1482*(6-LATE_EPOCH))
   $fatal(1,"RAW8_BOARD_FAIL counts pub=%0d under=%0d writes=%0d fences=%0d packets=%0d",published,underflows,writes,fences,packet_count);
  $fclose(hexfile);$fclose(lenfile);
  $display("RAW8_BOARD_CORE_PASS published=%0d hdmi_frames=%0d network_frames=%0d packets=%0d",published,hdmi_frames,net_frames,packet_count);$finish;
 end
 initial begin #300000000;$fatal(1,"RAW8_BOARD_TIMEOUT pub=%0d state=%0d writer=%0d",published,dut.cstate,dut.u_writer.state);end
endmodule
