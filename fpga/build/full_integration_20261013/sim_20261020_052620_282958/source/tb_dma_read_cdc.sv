`timescale 1ns/1ps
// Purpose: asynchronous request/payload/completion transfers with non-harmonic
// clocks, stopped client clock, held ACK, cancellation and joint reset recovery.
module tb_dma_read_cdc;
 reg client_clk=0,memory_clk=0,client_running=1;
 always #6.7 if(client_running)client_clk=~client_clk;
 always #4 memory_clk=~memory_clk;
 reg client_rst_n=0,memory_rst_n=0,req_valid=0,cancel=0,r_ready=0,done_ready=0;
 reg [31:0] req_addr=0,req_tag=0;reg [4:0] req_beats=0;
 wire req_ready,r_valid,r_last,done,error,cancelled;wire [255:0] r_data;wire [31:0] done_tag;
 wire memory_req_valid,memory_cancel,memory_r_ready,memory_done_ready;
 wire [31:0] memory_req_addr,memory_req_tag;wire [4:0] memory_req_beats;
 reg memory_req_ready=0,memory_r_valid=0,memory_r_last=0,memory_done=0,memory_error=0,memory_cancelled=0;
 reg [255:0] memory_r_data=0;reg [31:0] memory_done_tag=0;
 dma_read_cdc dut(.*);
 integer state=0,beat=0,count=0,cycles=0,received=0,checks=0;
 reg [31:0] address=0,tag=0;
 reg block_req=0,block_data=0,expect_cancel=0;
 function [255:0] value(input integer a,b);
  reg [255:0] v;begin for(integer i=0;i<32;i++)v[i*8+:8]=8'(a+b*32+i*7);value=v;end
 endfunction
 always @(negedge memory_clk)begin
  memory_req_ready=memory_rst_n && state==0 && !block_req;
  memory_r_valid=memory_rst_n && state==1 && !block_data && cycles%3!=0;
  memory_r_data=value(address,beat);memory_r_last=beat==count-1;
  memory_done=memory_rst_n && state==2;
 end
 always @(posedge memory_clk)begin
  cycles++;
  if(!memory_rst_n)begin state=0;beat=0;memory_cancelled=0;end
  else begin
   if(memory_req_valid && memory_req_ready)begin
    address=memory_req_addr;tag=memory_req_tag;count=memory_req_beats;beat=0;
    memory_done_tag=memory_req_tag;memory_cancelled=0;state=1;
   end
   if(memory_cancel)memory_cancelled=1;
   if(memory_r_valid && memory_r_ready)begin beat++;if(beat==count)state=2;end
   if(memory_done && memory_done_ready)state=0;
  end
 end
 always @(negedge client_clk)r_ready=cycles%5!=0;
 always @(posedge client_clk)if(client_rst_n && r_valid && r_ready)begin
  if(r_data!==value(address,received) || r_last!=(received==count-1))$fatal(1,"CDC_FAIL payload/last");
  received++;checks++;
 end
 task submit(input integer a,n,t);
  begin @(negedge client_clk);req_addr=a;req_tag=t;req_beats=n;req_valid=1;received=0;
   #1;while(!req_ready)begin @(negedge client_clk);#1;end
   @(posedge client_clk);@(negedge client_clk);req_valid=0;req_addr=32'hffffffff;req_tag=0;req_beats=0;
  end
 endtask
 task acknowledge(input integer t,input logic was_cancelled);
  begin wait(done);@(negedge client_clk);
   if(error || cancelled!=was_cancelled || done_tag!=t)$fatal(1,"CDC_FAIL status/tag");
   repeat(6)@(negedge client_clk);if(!done || req_ready)$fatal(1,"CDC_FAIL held completion");
   done_ready=1;@(negedge client_clk);done_ready=0;cancel=0;repeat(8)@(negedge client_clk);
  end
 endtask
 initial begin
  repeat(4)@(negedge memory_clk);client_rst_n=1;memory_rst_n=1;
  submit(32'h12340,16,7);acknowledge(7,0);if(received!=16)$fatal(1,"CDC_FAIL missing beats");
  submit(32'h34560,1,8);acknowledge(8,0);
  block_req=1;submit(32'h56780,8,9);wait(memory_req_valid);cancel=1;
  repeat(10)@(negedge memory_clk);if(done || !memory_req_valid)$fatal(1,"CDC_FAIL address withdrawal");
  block_req=0;acknowledge(9,1);if(received!=0)$fatal(1,"CDC_FAIL cancelled payload escaped");
  // Destination can finish while the consumer clock is absent; RAM and held
  // metadata must survive until the original client resumes and consumes them.
  block_data=1;submit(32'h789a0,16,10);wait(memory_req_valid && memory_req_ready);
  @(negedge client_clk);client_running=0;block_data=0;repeat(100)@(negedge memory_clk);
  if(state!=0)$fatal(1,"CDC_FAIL stopped client blocked native drain");
  client_running=1;acknowledge(10,0);if(received!=16)$fatal(1,"CDC_FAIL resume data");
  // Both domain resets coincide with model/native reset; no one-sided flush.
  block_data=1;submit(32'h11120,16,11);repeat(10)@(negedge memory_clk);
  client_rst_n=0;memory_rst_n=0;repeat(8)@(negedge memory_clk);client_rst_n=1;memory_rst_n=1;block_data=0;
  repeat(8)@(negedge client_clk);submit(32'h22240,3,12);acknowledge(12,0);
  if(received!=3)$fatal(1,"CDC_FAIL joint reset stale response");
  $display("DMA_READ_CDC_PASS checked_beats=%0d",checks);$finish;
 end
 initial begin #2000000;$fatal(1,"CDC_TIMEOUT");end
endmodule
