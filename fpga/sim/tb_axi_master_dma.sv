`timescale 1ns/1ps
// Purpose: retained standard-AXI master regression; independent WR/RD lengths,
// synchronous FIFO latency, tail strobe, page split, B delay, R backpressure.
module tb_axi_master_dma;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,master_rst=0,wr_start=0,rd_start=0;
 reg [31:0] addr=0,length=0;
 wire wr_ready,rd_ready,pop,push,wdone,rdone,werror,rerror;
 reg [255:0] fifo_data=0;wire [255:0] read_data;
 reg empty=0,full=0;
 wire [31:0] awaddr,araddr;wire [7:0] awlen,arlen;
 wire awvalid,arvalid,wvalid,wlast,bready,rready;
 wire [255:0] wdata;wire [31:0] wstrb;
 reg awready=0,arready=0,wready=0,bvalid=0,rvalid=0,rlast=0;
 reg [1:0] bresp=0,rresp=0;reg [255:0] rdata=0;
 aq_axi_master_256 dut(
  .ARESETN(rst_n),.ACLK(clk),.MASTER_RST(master_rst),
  .M_AXI_AWADDR(awaddr),.M_AXI_AWLEN(awlen),.M_AXI_AWVALID(awvalid),.M_AXI_AWREADY(awready),
  .M_AXI_WDATA(wdata),.M_AXI_WSTRB(wstrb),.M_AXI_WLAST(wlast),.M_AXI_WVALID(wvalid),.M_AXI_WREADY(wready),
  .M_AXI_BID(1'b0),.M_AXI_BRESP(bresp),.M_AXI_BUSER(1'b0),.M_AXI_BVALID(bvalid),.M_AXI_BREADY(bready),
  .M_AXI_ARADDR(araddr),.M_AXI_ARLEN(arlen),.M_AXI_ARVALID(arvalid),.M_AXI_ARREADY(arready),
  .M_AXI_RID(1'b0),.M_AXI_RDATA(rdata),.M_AXI_RRESP(rresp),.M_AXI_RLAST(rlast),.M_AXI_RUSER(1'b0),.M_AXI_RVALID(rvalid),.M_AXI_RREADY(rready),
  .WR_START(wr_start),.WR_ADRS(addr),.WR_LEN(length),.WR_READY(wr_ready),
  .WR_FIFO_RE(pop),.WR_FIFO_EMPTY(empty),.WR_FIFO_AEMPTY(1'b0),.WR_FIFO_DATA(fifo_data),.WR_DONE(wdone),.WR_ERROR(werror),
  .RD_START(rd_start),.RD_ADRS(addr),.RD_LEN(length+32'd1000),.RD_READY(rd_ready),
  .RD_FIFO_WE(push),.RD_FIFO_FULL(full),.RD_FIFO_AFULL(1'b0),.RD_FIFO_DATA(read_data),.RD_DONE(rdone),.RD_ERROR(rerror));
 integer seed=121,seed_arg,popped=0,wleft=0,rleft=0,base=0,wb=0,rb=0,write_seen=0,read_seen=0,next_aw=0,next_ar=0,bdelay=-1,tests=0;
 reg error_case=0,force_full=0;
 function automatic [255:0] pattern(input integer x);
  for(integer b=0;b<32;b=b+1) pattern[b*8+:8]=(x*11+b*5+7)&255;
 endfunction
 // Purpose: genuine AXI return holds valid and data when the receiver stalls.
 always @(negedge clk) begin
  awready=rst_n&&wleft==0&&!bvalid&&($random(seed)&3)!=0;
  arready=rst_n&&rleft==0&&($random(seed)&3)!=0;
  wready=rst_n&&wleft>0&&($random(seed)&3)!=0;
  empty=($random(seed)&7)==0;full=force_full || ($random(seed)&3)==0;
  if(!rvalid) begin
   rvalid=rst_n&&rleft>0&&($random(seed)&3)!=0;rdata=pattern(read_seen);rlast=rleft==1;
  end
  if(bdelay==0) begin bvalid=1;bresp=error_case?2'b10:0;bdelay=-1;end
  else if(bdelay>0)bdelay=bdelay-1;
 end
 always @(posedge clk) if(rst_n) begin
  if(pop) begin fifo_data<=pattern(popped);popped=popped+1;end
  if(awvalid&&awready) begin
   if(awaddr!=next_aw || awlen>15 || awaddr%4096+(awlen+1)*32>4096)$fatal(1,"AXI burst split");
   wleft=awlen+1;next_aw=awaddr+wleft*32;wb=0;
  end
  if(wvalid&&wready) begin
   if(wdata!==pattern(write_seen))$fatal(1,"AXI FIFO accounting");
   for(integer b=0;b<32;b=b+1) if(wstrb[b]!=(write_seen*32+b<length))$fatal(1,"AXI tail strobe");
   if(wlast!=(wleft==1))$fatal(1,"AXI WLAST");
   wleft=wleft-1;write_seen=write_seen+1;
   if(wleft==0)bdelay=9;
  end
  // NBA deassertion lets DUT and scoreboard observe the same response edge.
  if(bvalid&&bready)bvalid<=0;
  if(wdone && (wleft!=0 || bvalid || bdelay>=0))$fatal(1,"AXI early write done");
  if(arvalid&&arready) begin
   if(araddr!=next_ar || arlen>15 || araddr%4096+(arlen+1)*32>4096)$fatal(1,"AXI read split");
   rleft=arlen+1;next_ar=araddr+rleft*32;
  end
  if(push!=(rvalid&&rready&&!master_rst)) begin
   // During cancellation, the retained rcancel also suppresses the FIFO.
   if(!master_rst && !dut.rcancel)$fatal(1,"AXI read FIFO without handshake");
  end
  if(rvalid&&rready) begin
   if(push && read_data!==pattern(read_seen))$fatal(1,"AXI read data");
   rleft=rleft-1;read_seen=read_seen+1;rvalid<=0;
  end
 end
 task automatic write_case(input integer a,input integer n,input bit err);
  begin
   @(negedge clk);addr=a;length=n;popped=0;write_seen=0;next_aw=a;error_case=err;wr_start=1;
   @(negedge clk);wr_start=0;wait(wdone);@(negedge clk);
   if(werror!=err || popped!=(n+31)/32 || write_seen!=(n+31)/32)$fatal(1,"AXI write result");
   wait(wr_ready);tests=tests+1;
  end
 endtask
 initial begin
  if($value$plusargs("seed=%d",seed_arg))seed=seed_arg;
  repeat(4)@(negedge clk);rst_n=1;
  write_case(0,1,0);write_case(4096,33,0);write_case(4064,1025,0);write_case(8192,65,1);
  // Read byte length deliberately differs from WR_LEN; full causes R stalls.
  @(negedge clk);addr=4064;length=25;next_ar=addr;read_seen=0;rd_start=1;
  @(negedge clk);rd_start=0;wait(rdone);@(negedge clk);
  if(rerror || read_seen!=(1025+31)/32)$fatal(1,"AXI read count/backpressure");tests=tests+1;
  wait(rd_ready);@(negedge clk);length=0;wr_start=1;@(negedge clk);wr_start=0;
  wait(wdone);if(!werror)$fatal(1,"AXI zero length accepted");
  wait(wr_ready);@(negedge clk);addr=8192;length=1025;popped=0;write_seen=0;next_aw=addr;wr_start=1;error_case=0;
  @(negedge clk);wr_start=0;wait(dut.ws==3);@(negedge clk);master_rst=1;
  wait(wdone);@(negedge clk);
  if(!werror || write_seen!=16 || popped!=16)$fatal(1,"AXI write cancellation did not drain current burst");
  master_rst=0;tests=tests+1;wait(wr_ready);
  @(negedge clk);addr=4064;length=25;next_ar=addr;read_seen=0;rd_start=1;
  @(negedge clk);rd_start=0;wait(dut.rs==2);@(negedge clk);master_rst=1;force_full=1;
  wait(rdone);@(negedge clk);
  if(!rerror || read_seen!=1 || rleft!=0)$fatal(1,"AXI read cancellation/full FIFO did not drain");
  master_rst=0;force_full=0;tests=tests+1;
  $display("AXI_MASTER_DMA_PASS tests=%0d",tests+1);$finish;
 end
 initial begin #1000000;$fatal(1,"AXI_MASTER_DMA_TIMEOUT ws=%0d rs=%0d popped=%0d captured=%0d wn=%0d bdelay=%0d",dut.ws,dut.rs,popped,dut.captured,dut.wn,bdelay);end
endmodule
