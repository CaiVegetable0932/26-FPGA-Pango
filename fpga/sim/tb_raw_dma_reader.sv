`timescale 1ns/1ps
// Unaligned 35B rows at stride64 exercise head skip/cross-beat/tail trimming,
// slot-rounded rejection and cancellation of an actually issued read. Contract
// model completes only after every in-flight byte beat is drained.
module tb_raw_dma_reader;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,start=0,cancel=0;
 reg [31:0] base_addr=31,slot_begin=0,slot_end=256;
 wire start_ready,done,failed,req_valid,req_ready,r_ready,dma_done_ready,dma_cancel,byte_valid;
 wire [31:0] req_addr;wire [4:0] req_beats;wire [7:0] byte_data;
 reg r_valid=0,dma_done=0,byte_ready=0;reg [255:0] r_data=0;
 integer state=0,addr=0,beats=0,beat=0,delay_count=0,cycle=0,j,p,row,col,count=0;
 reg cancelled_phase=0;
 assign req_ready=state==0;
 raw_dma_reader #(.WIDTH(35),.HEIGHT(3),.STRIDE(64)) dut(.*,.dma_error(1'b0));
 always @(negedge clk) if(rst_n) begin
  r_valid=0;dma_done=0;byte_ready=(cycle%4!=0);
  if(state==1) begin if(delay_count==0) state=2;else delay_count=delay_count-1;end
  else if(state==2) begin
   r_valid=1;
   for(j=0;j<32;j=j+1) begin
    p=addr+beat*32+j-31;row=p/64;col=p%64;
    r_data[j*8+:8]=(p>=0 && col<35)?(row*7+col*3+17):8'he7;
   end
  end else if(state==3) dma_done=1;
 end
 always @(posedge clk) if(rst_n) begin
  cycle=cycle+1;
  if(cycle==1000 && $test$plusargs("debug")) begin
   $display("reader state=%0d row=%0d loaded=%0d ended=%0d count=%0d model=%0d cancelled=%b ready=%b",dut.state,dut.row,dut.loaded,dut.row_ended,count,state,cancelled_phase,byte_ready);$finish;
  end
  if(req_valid && req_ready) begin addr=req_addr;beats=req_beats;beat=0;delay_count=20;state<=1;end
  else if(r_valid && r_ready) begin beat=beat+1;if(beat==beats) state<=3;end
  else if(dma_done && dma_done_ready) state<=0;
  if(byte_valid && byte_ready) begin
   if(cancelled_phase) $fatal(1,"byte leaked after cancel");
   if(byte_data!=((count/35)*7+(count%35)*3+17)) $fatal(1,"row compaction %0d",count);
   count=count+1;
  end
 end
 task begin_read;
  begin wait(start_ready);@(negedge clk);start=1;@(negedge clk);start=0;end
 endtask
 initial begin
  repeat(5) @(negedge clk);rst_n=1;
  begin_read();wait(done);@(negedge clk);if(failed || count!=105) $fatal(1,"complete compact frame");
  slot_end=192;begin_read();wait(done);if(!failed || req_valid) $fatal(1,"rounded slot bound");
  slot_end=256;begin_read();wait(state==1);@(negedge clk);cancel=1;cancelled_phase=1;
  repeat(10) @(negedge clk);if(done || !dma_cancel) $fatal(1,"early cancel completion");
  wait(done);if(!failed || state!=0) $fatal(1,"cancel not drained");
  $display("RAW_DMA_READER_PASS bytes=105 unaligned/slot/cancel");$finish;
 end
 initial begin #100000;$fatal(1,"reader timeout");end
endmodule
