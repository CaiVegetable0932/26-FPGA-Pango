`timescale 1ns/1ps
// Purpose: diagnostic FIFO one-cycle latency and native address/LAST scoreboard.
module tb_mini_ddr_native_bridge;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,wr_req=0,rd_req=0;
 reg [9:0] wr_beats=0,rd_beats=0;reg [24:0] wr_beat_addr=0,rd_beat_addr=0;
 wire wr_data_req,wr_finish,rd_data_valid,rd_finish,fault;
 reg [255:0] wr_data=0;wire [255:0] rd_data,wdata;wire [31:0] wstrb;
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,awid,arid;wire awvalid,arvalid;
 reg awready=0,arready=0,wready=0,wlast=0,rvalid=0,rlast=0;
 reg [3:0] wid=0,rid=0;reg [255:0] rdata=0;
 mini_ddr_native_bridge dut(.*);
 integer seed=909,seed_arg,n=0,wp=0,wleft=0,wi=0,rleft=0,ri=0,seen=0,tests=0;
 reg inject=0;
 function automatic [255:0] value(input integer index);
  for(integer b=0;b<32;b=b+1) value[b*8+:8]=(index*41+b*7)&255;
 endfunction
 // Purpose: model the actual non-FWFT FIFO: data is assigned after pop edge.
 always @(posedge clk) begin
  if(!rst_n) begin wp=0;wleft=0;rleft=0;wi=0;ri=0;end
  else begin
   if(wr_data_req) begin wr_data<=value(wp);wp=wp+1;end
   if(awvalid&&awready) begin
    if(awaddr!=wr_beat_addr*8 || awlen!=wr_beats-1 || wp!=wr_beats || awid!=0)
     $fatal(1,"diagnostic AW/address/prefetch mismatch");
    wleft=awlen+1;wi=0;
   end
   if(wready) begin
    if(wdata!==value(wi) || wstrb!==32'hffffffff) $fatal(1,"FIFO prefetch lost/repeated beat");
    wleft=wleft-1;wi=wi+1;
   end
   if(arvalid&&arready) begin
    if(araddr!=rd_beat_addr*8 || arlen!=rd_beats-1 || arid!=0) $fatal(1,"diagnostic AR conversion");
    rleft=arlen+1;ri=0;
   end
   if(rvalid) begin rleft=rleft-1;ri=ri+1;end
   if(rd_data_valid) begin if(rd_data!==value(seen)) $fatal(1,"diagnostic read data");seen=seen+1;end
   if(wr_finish && wleft!=0) $fatal(1,"early diagnostic write finish");
   if(rd_finish && rleft!=0) $fatal(1,"early diagnostic read finish");
  end
 end
 always @(negedge clk) begin
  awready=rst_n&&($random(seed)&3)!=0;arready=rst_n&&($random(seed)&3)!=0;
  wready=rst_n&&wleft!=0&&($random(seed)&3)!=0;wlast=(wleft==1)&&!inject;
  rvalid=rst_n&&rleft!=0&&($random(seed)&3)!=0;rlast=rleft==1;rdata=value(ri);
 end
 initial begin
  if($value$plusargs("seed=%d",seed_arg)) seed=seed_arg;
  repeat(4) @(negedge clk);rst_n=1;
  for(n=1;n<=16;n=n+1) begin
   @(negedge clk);wp=0;seen=0;wr_beats=n;rd_beats=n;wr_beat_addr=n*128;rd_beat_addr=n*128;
   wr_req=1;rd_req=1;
   fork
    begin wait(wr_finish);@(negedge clk);wr_req=0;end
    begin wait(rd_finish);@(negedge clk);rd_req=0;end
   join
   if(seen!=n || wp!=n) $fatal(1,"diagnostic beat count");tests=tests+1;
   repeat(4) @(negedge clk);
  end
  if(fault) $fatal(1,"unexpected diagnostic fault");
  // Wrong native LAST must never publish a write finish.
  inject=1;@(negedge clk);wp=0;wr_beats=1;wr_beat_addr=4096;wr_req=1;
  wait(fault);repeat(8) @(negedge clk);if(wr_finish)$fatal(1,"fault published");wr_req=0;
  $display("MINI_DDR_BRIDGE_PASS tests=%0d",tests+1);$finish;
 end
 initial begin #1000000;$fatal(1,"MINI_DDR_BRIDGE_TIMEOUT");end
endmodule
