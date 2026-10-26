`timescale 1ns/1ps
// Purpose: frame schedulers must reserve/advance actual 16+3 word tail bursts.
module tb_frame_dma_tail;
 reg clk=0;always #4 clk=~clk;
 reg rst=1,req=0;wire wa,ra,wf,rf,wb,rb;
 wire [9:0] wl,rl;wire [24:0] waddr,raddr;
 reg wfinish=0,rfinish=0,rvalid=0;
 wire wclear,rclear;
 frame_fifo_write #(.MEM_DATA_BITS(256),.ADDR_BITS(25),.BURST_SIZE(16)) w(
  .rst(rst),.mem_clk(clk),.wr_burst_req(wb),.wr_burst_len(wl),.wr_burst_addr(waddr),
  .wr_burst_data_req(1'b0),.wr_burst_finish(wfinish),.write_req(req),.write_req_ack(wa),.write_finish(wf),
  .write_addr_0(25'd128),.write_addr_1(25'd0),.write_addr_2(25'd0),.write_addr_3(25'd0),.write_addr_index(2'd0),
  .write_len(25'd19),.fifo_aclr(wclear),.rdusedw(16'd19));
 frame_fifo_read #(.MEM_DATA_BITS(256),.ADDR_BITS(25),.BURST_SIZE(16),.FIFO_DEPTH(256)) r(
  .rst(rst),.mem_clk(clk),.rd_burst_req(rb),.rd_burst_len(rl),.rd_burst_addr(raddr),
  .rd_burst_data_valid(rvalid),.rd_burst_finish(rfinish),.read_req(req),.read_req_ack(ra),.read_finish(rf),
  .read_addr_0(25'd128),.read_addr_1(25'd0),.read_addr_2(25'd0),.read_addr_3(25'd0),.read_addr_index(2'd0),
  .read_len(25'd19),.fifo_aclr(rclear),.wrusedw(16'd0));
 integer nw=0,nr=0;
 initial begin
  repeat(4) @(negedge clk);rst=0;req=1;wait(wa&&ra);@(negedge clk);req=0;
  fork
   begin
    for(integer i=0;i<2;i=i+1) begin
     wait(wb);@(negedge clk);
     if(waddr!=(i==0?128:144) || wl!=(i==0?16:3))$fatal(1,"write tail/address");
     repeat(9) @(negedge clk);if(wf)$fatal(1,"early frame write finish");
     wfinish=1;@(negedge clk);wfinish=0;wait(!wb);nw=nw+1;
    end
    wait(wf);
   end
   begin
    for(integer i=0;i<2;i=i+1) begin
     wait(rb);@(negedge clk);
     if(raddr!=(i==0?128:144) || rl!=(i==0?16:3))$fatal(1,"read tail/address");
     repeat(9) @(negedge clk);if(rf)$fatal(1,"early frame read finish");
     rvalid=1;rfinish=1;@(negedge clk);rvalid=0;rfinish=0;wait(!rb);nr=nr+1;
    end
    wait(rf);
   end
  join
  if(nw!=2 || nr!=2)$fatal(1,"tail count");$display("FRAME_DMA_TAIL_PASS");$finish;
 end
 initial begin #1000000;$fatal(1,"FRAME_DMA_TAIL_TIMEOUT");end
endmodule
