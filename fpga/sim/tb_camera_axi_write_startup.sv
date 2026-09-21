`timescale 1ns/1ps
// Purpose: reproduce the first camera write before any display read exists.
// A 512-byte burst must consume exactly sixteen 256-bit FIFO words, regardless
// of the independent read length. Check payload continuity under WREADY stalls.
module tb_camera_axi_write_startup;
 reg clk=0,reset_n=0,start=0,wready=1;
 reg [31:0] read_len=0;
 always #4 clk=~clk;
 wire pop,done,wvalid,wlast;
 wire [255:0] wdata;
 reg [255:0] fifo_data=0;
 integer pops=0,beats=0,cycle=0;
 // Purpose: insert deterministic backpressure without racing active clock edges.
 always @(negedge clk) begin cycle=cycle+1;wready=(cycle%4!=0);end
 aq_axi_master_256 dut(.ACLK(clk),.ARESETN(reset_n),.MASTER_RST(1'b0),
 .WR_START(start),.WR_ADRS(32'd0),.WR_LEN(32'd512),.WR_FIFO_RE(pop),
 .WR_FIFO_EMPTY(1'b0),.WR_FIFO_AEMPTY(1'b0),.WR_FIFO_DATA(fifo_data),.WR_DONE(done),
 .M_AXI_AWREADY(1'b1),.M_AXI_WREADY(wready),.M_AXI_BVALID(1'b1),
 .M_AXI_BID(1'b0),.M_AXI_BRESP(2'b0),.M_AXI_BUSER(1'b0),
 .M_AXI_WVALID(wvalid),.M_AXI_WDATA(wdata),.M_AXI_WLAST(wlast),
 .RD_START(1'b0),.RD_ADRS(32'd0),.RD_LEN(read_len),.RD_FIFO_FULL(1'b0),
 .RD_FIFO_AFULL(1'b0),.M_AXI_ARREADY(1'b1),.M_AXI_RVALID(1'b0),
 .M_AXI_RID(1'b0),.M_AXI_RDATA(256'd0),.M_AXI_RRESP(2'b0),
 .M_AXI_RLAST(1'b0),.M_AXI_RUSER(1'b0));
 always @(posedge clk) if(reset_n) begin
  if(wvalid && wready) begin
   if(wdata!==beats || wlast!==(beats==15)) $fatal(1,"AXI_WRITE_FAIL: payload/last");
   beats=beats+1;
  end
  if(pop) begin fifo_data<=pops;pops=pops+1;end
 end
 task burst(input [31:0] other_length);
  begin
   reset_n=0;repeat(3) @(negedge clk);
   pops=0;beats=0;fifo_data=0;read_len=other_length;reset_n=1;
   @(negedge clk);start=1;@(negedge clk);start=0;
   wait(done);@(negedge clk);
   $display("AXI_WRITE_COUNTS read_len=%0d pops=%0d beats=%0d",other_length,pops,beats);
   if(pops!=16 || beats!=16) $fatal(1,"AXI_WRITE_FAIL: FIFO overread at startup");
  end
 endtask
 initial begin
  burst(0);burst(512);burst(1024);
  $display("AXI_WRITE_STARTUP_PASS");$finish;
 end
 initial begin #10000;$fatal(1,"AXI_WRITE_TIMEOUT");end
endmodule
