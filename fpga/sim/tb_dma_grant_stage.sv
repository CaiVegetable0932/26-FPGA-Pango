`timescale 1ns/1ps
// Verify the new pre-VALID reservation at its cancellation boundary. Native
// VALID must persist once published; a pre-publication cancellation must issue
// no address and must not consume round-robin/urgent credit.
module tb_dma_grant_stage;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,controller_ready=1;
 reg [2:0] req_valid=0,req_write=0,urgent=0,cancel=0,w_valid=0,done_ready=0;
 wire [2:0] req_ready,w_ready,done,cancelled,r_valid;
 reg [95:0] req_addr=0,req_tag=0;reg [14:0] req_beats=0;
 wire arvalid,awvalid;wire [27:0] araddr;wire [3:0] arlen;
 reg arready=0,native_rvalid=0,native_rlast=0;
 reg [255:0] native_rdata=0;
 integer issued=0,checks=0;
 ddr_native_dma #(.CLIENTS(3)) dut(.clk(clk),.rst_n(rst_n),.controller_ready(controller_ready),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),
  .req_tag(req_tag),.req_beats(req_beats),.urgent(urgent),.cancel(cancel),
  .w_valid(w_valid),.w_ready(w_ready),.w_data(768'd0),.w_strb(96'd0),
  .done(done),.done_ready(done_ready),.cancelled(cancelled),.r_valid(r_valid),.r_ready(3'b111),
  .awvalid(awvalid),.awready(1'b0),.native_wready(1'b0),.native_wid(4'd0),.native_wlast(1'b0),
  .arvalid(arvalid),.araddr(araddr),.arlen(arlen),.arready(arready),
  .native_rvalid(native_rvalid),.native_rdata(native_rdata),.native_rid(4'd0),.native_rlast(native_rlast));
 always @(posedge clk)if(rst_n && arvalid && arready)issued++;
 task submit(input integer c,input bit wr,input integer beats);
  begin
   @(negedge clk);req_valid[c]=1;req_write[c]=wr;
   req_addr[c*32+:32]=4096+c*512;req_beats[c*5+:5]=beats;req_tag[c*32+:32]=c+17;
   do @(posedge clk);while(!req_ready[c]);
   @(negedge clk);req_valid[c]=0;
  end
 endtask
 task acknowledge(input integer c);
  begin wait(done[c]);@(negedge clk);done_ready[c]=1;@(negedge clk);done_ready[c]=0;cancel[c]=0;end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  // An incomplete urgent write must not reserve the port ahead of ready reads.
  urgent[0]=1;submit(0,1,2);repeat(6)@(negedge clk);
  if(awvalid || arvalid || dut.state!=dut.IDLE)$fatal(1,"incomplete write reserved port");
  submit(1,0,1);wait(dut.state==dut.SELECT);@(negedge clk);cancel[1]=1;
  @(negedge clk);
  if(arvalid || awvalid || !done[1] || !cancelled[1] || issued!=0 || dut.rr!=0 || dut.emergency_run!=0)
   $fatal(1,"cancelled reservation issued or consumed credit");
  checks++;acknowledge(1);
  // Once ARVALID has appeared, cancelling with ARREADY low cannot withdraw it.
  submit(2,0,2);wait(arvalid);@(negedge clk);cancel[2]=1;
  repeat(5)begin @(negedge clk);if(!arvalid || araddr!=1280 || arlen!=1 || done[2])$fatal(1,"AR not held through cancel");end
  arready=1;@(negedge clk);arready=0;
  native_rvalid=1;native_rlast=0;@(negedge clk);native_rlast=1;
  @(negedge clk);native_rvalid=0;native_rlast=0;
  if(!done[2] || !cancelled[2] || r_valid[2] || issued!=1)$fatal(1,"cancelled native read not drained");
  checks++;acknowledge(2);
  // A new generation in the same queue cannot inherit the aborted grant.
  submit(1,0,1);wait(arvalid);@(negedge clk);arready=1;
  @(negedge clk);arready=0;native_rvalid=1;native_rlast=1;
  @(negedge clk);native_rvalid=0;native_rlast=0;
  wait(done[1]);if(cancelled[1] || issued!=2)$fatal(1,"replacement generation poisoned");
  checks++;acknowledge(1);
  cancel[0]=1;acknowledge(0);
  $display("DMA_GRANT_STAGE_PASS checks=%0d issued=%0d",checks,issued);$finish;
 end
 initial begin #100000;$fatal(1,"DMA_GRANT_STAGE_TIMEOUT");end
endmodule
