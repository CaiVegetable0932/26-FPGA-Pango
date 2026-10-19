`timescale 1ns/1ps
// Independent tile producer and quad/metadata consumer; no reference RTL.
module tile_cdc_tb;
 parameter real PROC_HALF=3.333,MEM_HALF=4.0,MEM_PHASE=0.7;
 parameter ALWAYS_READY=0;
 reg pc=0,mc=0,prun=1,prst=0,mrst=0;
 always #PROC_HALF if(prun)pc=~pc;
 initial begin #MEM_PHASE;forever #MEM_HALF mc=~mc;end
 reg req=0,fr=0,mready=0,mv=0,ml=0,me=0;
 reg [11:0] tx=0,ty=0;reg [95:0] md=0;reg [31:0] mb=0;
 wire ready,fv,fl,fe,busy,mreq,mfr;wire [95:0] fd;wire [31:0] fb;wire [11:0] mx,my;
 tile_refill_cdc dut(pc,prst,req,ready,tx,ty,fv,fr,fd,fl,fe,fb,busy,mc,mrst,mreq,mready,mx,my,mv,mfr,md,ml,me,mb);
 integer n,index=0,length=0,tag=0,checks=0,cycles=0,cases=0,stalls=0;
 reg failure=0,hold_client=0;
 function [95:0] value(input integer job,beat);
  begin for(integer b=0;b<12;b=b+1)value[b*8+:8]=8'(job*29+beat*17+b*71);end
 endfunction
 function [31:0] bus_bytes(input integer beat);
  bus_bytes=(beat/16+1)*192;
 endfunction
 always @(negedge pc)begin cycles=cycles+1;fr=prst && !hold_client && (ALWAYS_READY || cycles%7>1);end
 reg stalled=0;reg [129:0] held;
 always @(posedge pc)begin
  if(prst && stalled && (!fv || {fl,fe,fb,fd}!==held))$fatal(1,"Quad changed under backpressure");
  stalled=prst && fv && !fr;held={fl,fe,fb,fd};
  if(prst && fv && fr)begin
   if(fd!==value(tag,index) || fb!==bus_bytes(index) || fl!==(index==length-1) || fe!==(failure && index==length-1))
    $fatal(1,"Quad/last/error/byte counter lost atomicity job=%0d beat=%0d",tag,index);
   if(!busy)$fatal(1,"Client ownership released before LAST");
   index=index+1;checks=checks+1;
  end
 end
 task resets;
  begin
   prst=0;mrst=0;req=0;mv=0;mready=0;hold_client=0;prun=1;index=0;
   #31;@(negedge mc);mrst=1;@(negedge pc);prst=1;
   repeat(8)@(negedge pc);if(fv || busy || !ready)$fatal(1,"Reset retained old quads");
  end
 endtask
 task transaction(input integer job,count,input logic failed,input logic stop_clock);
  begin
   tag=job;length=count;failure=failed;index=0;
   fork
    begin
     @(negedge pc);tx=job*131;ty=job*197;req=1;
     @(posedge pc);while(!ready)@(posedge pc);
     @(negedge pc);req=0;tx='x;ty='x;
     wait(index==count);@(negedge pc);
     if(busy || !ready)$fatal(1,"Last quad did not release client");
    end
    begin:memory_producer
     integer beat;
     wait(mreq);
     repeat(job%7+1)begin
      @(negedge mc);
      if(!mreq || mx!==12'(job*131) || my!==12'(job*197))$fatal(1,"Tile mailbox changed while stalled");
     end
     mready=1;@(negedge mc);mready=0;
     for(beat=0;beat<count;beat=beat+1)begin
      repeat((job+beat)%3)@(negedge mc);
      mv=1;md=value(job,beat);mb=bus_bytes(beat);ml=beat==count-1;me=failed && ml;
      @(posedge mc);while(!mfr)begin stalls=stalls+1;@(posedge mc);end
      @(negedge mc);mv=0;md='x;mb='x;ml='x;me='x;
     end
    end
    begin
     if(stop_clock)begin
      wait(index==5);@(negedge pc);prun=0;
      repeat(80)@(negedge mc);
      if(!busy || ready)$fatal(1,"Stopped client lost tile ownership");
      prun=1;
     end
    end
   join
   cases=cases+1;repeat(8)@(negedge pc);
  end
 endtask
 initial begin
  resets;
  for(n=0;n<20;n=n+1)transaction(n,n%5==0 ? (1+n*17)%128:128,n%5==0,n==3);
  // Reset with unread FIFO words; the following job must contain no stale data.
  tag=99;length=128;failure=0;index=0;hold_client=1;
  @(negedge pc);tx=1;ty=2;req=1;@(negedge pc);req=0;
  wait(mreq);@(negedge mc);mready=1;@(negedge mc);mready=0;
  repeat(8)begin mv=1;md=96'hdead;mb=32'hdead;ml=0;me=0;@(negedge mc);end
  resets;transaction(100,128,0,0);
  if(cases!=21 || stalls==0)$fatal(1,"Coverage or backpressure missing");
  $display("TILE_REFILL_CDC_PASS cases=%0d quads=%0d stalls=%0d",cases,checks,stalls);$finish;
 end
 initial begin #2000000;$fatal(1,"Tile CDC watchdog");end
endmodule
