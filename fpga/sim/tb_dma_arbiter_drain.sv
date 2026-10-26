`timescale 1ns/1ps
// Purpose: a >8000-cycle native stall must not discard either arbiter owner.
module tb_dma_arbiter_drain;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,req=0,finish=0,write_pop=0,read_valid=0;
 wire wreq,rreq,wdata_req,rdata_valid,wfinish,rfinish;
 wire [9:0] wlen,rlen;wire [24:0] waddr,raddr;wire [255:0] wdata,rdata;
 mem_write_arbi #(.MEM_DATA_BITS(256),.ADDR_BITS(25)) w(
  .rst_n(rst_n),.mem_clk(clk),
  .ch0_wr_burst_req(req),.ch0_wr_burst_len(10'd1),.ch0_wr_burst_addr(25'd128),
  .ch0_wr_burst_data_req(wdata_req),.ch0_wr_burst_data(256'hdeadbeef),.ch0_wr_burst_finish(wfinish),
  .ch1_wr_burst_req(1'b0),.ch1_wr_burst_len(10'd0),.ch1_wr_burst_addr(25'd0),.ch1_wr_burst_data(256'd0),
  .ch2_wr_burst_req(1'b0),.ch2_wr_burst_len(10'd0),.ch2_wr_burst_addr(25'd0),.ch2_wr_burst_data(256'd0),
  .ch3_wr_burst_req(1'b0),.ch3_wr_burst_len(10'd0),.ch3_wr_burst_addr(25'd0),.ch3_wr_burst_data(256'd0),
  .wr_burst_req(wreq),.wr_burst_len(wlen),.wr_burst_addr(waddr),.wr_burst_data_req(write_pop),.wr_burst_data(wdata),.wr_burst_finish(finish));
 mem_read_arbi #(.MEM_DATA_BITS(256),.ADDR_BITS(25)) r(
  .rst_n(rst_n),.mem_clk(clk),
  .ch0_rd_burst_req(req),.ch0_rd_burst_len(10'd1),.ch0_rd_burst_addr(25'd128),
  .ch0_rd_burst_data_valid(rdata_valid),.ch0_rd_burst_data(rdata),.ch0_rd_burst_finish(rfinish),
  .ch1_rd_burst_req(1'b0),.ch1_rd_burst_len(10'd0),.ch1_rd_burst_addr(25'd0),
  .ch2_rd_burst_req(1'b0),.ch2_rd_burst_len(10'd0),.ch2_rd_burst_addr(25'd0),
  .ch3_rd_burst_req(1'b0),.ch3_rd_burst_len(10'd0),.ch3_rd_burst_addr(25'd0),
  .rd_burst_req(rreq),.rd_burst_len(rlen),.rd_burst_addr(raddr),.rd_burst_data_valid(read_valid),.rd_burst_data(256'h12345678),.rd_burst_finish(finish));
 initial begin
  repeat(4)@(negedge clk);rst_n=1;req=1;wait(wreq&&rreq);
  repeat(9000) begin
   @(negedge clk);
   if(wfinish || rfinish || w.write_state!=3 || r.read_state!=3 || waddr!=128 || raddr!=128)
    $fatal(1,"arbiter abandoned live transaction");
  end
  write_pop=1;read_valid=1;@(negedge clk);
  if(wdata!==256'hdeadbeef || rdata!==256'h12345678 || !wdata_req || !rdata_valid)$fatal(1,"arbiter owner/data mismatch");
  write_pop=0;read_valid=0;finish=1;req=0;@(negedge clk);finish=0;
  fork begin wait(wfinish);end begin wait(rfinish);end join
  $display("DMA_ARBITER_DRAIN_PASS stalled_cycles=9000");$finish;
 end
 initial begin #1000000;$fatal(1,"DMA_ARBITER_DRAIN_TIMEOUT");end
endmodule
