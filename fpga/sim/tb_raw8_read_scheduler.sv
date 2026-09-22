`timescale 1ns/1ps
// Purpose: check every 1080p DDR burst and address under delayed acceptance and
// completion. Padding and burst-over-row reads are forbidden independently.
module tb_raw8_read_scheduler;
 reg clk=0,rst=0,start=0,ready=0,finish=0;
 reg [27:0] base=28'h3400000;
 wire idle,request,done;wire [27:0] address;wire [4:0] length;
 integer row,col,bursts=0,words=0;
 reg [27:0] saved_addr;reg [4:0] saved_length;
 always #5 clk=~clk;
 raw8_read_scheduler dut(clk,rst,start,base,idle,request,ready,finish,address,length,done);
 initial begin
  repeat(4)@(negedge clk);rst=1;start=1;
  @(negedge clk);start=0;base=0;
  for(row=0;row<1080;row=row+1)for(col=0;col<60;col=col+16)begin
   wait(request);saved_addr=address;saved_length=length;
   if(address!=28'h3400000+row*2048+col*32 || length!=(col==48?12:16))
    $fatal(1,"RAW8_FAIL DDR geometry row=%0d col=%0d",row,col);
   repeat(3)begin @(negedge clk);
    if(address!=saved_addr || length!=saved_length || !request)$fatal(1,"RAW8_FAIL unstable request");end
   ready=1;@(negedge clk);ready=0;
   repeat(5)begin @(negedge clk);if(request)$fatal(1,"RAW8_FAIL premature request");end
   finish=1;@(negedge clk);finish=0;bursts=bursts+1;words=words+saved_length;
  end
  if(!done || !idle || bursts!=4320 || words!=64800)$fatal(1,"RAW8_FAIL read completion");
  $display("RAW8_READ_SCHEDULER_PASS bursts=%0d words=%0d",bursts,words);$finish;
 end
 initial begin #1000000;$fatal(1,"RAW8_TIMEOUT scheduler");end
endmodule
