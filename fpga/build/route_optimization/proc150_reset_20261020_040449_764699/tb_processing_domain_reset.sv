`timescale 1ns/1ps
// Behavioral native initialization follows the real integration contract:
// common controller reset clears ready asynchronously, even with no clock.
module processing_reset_tb;
 reg cclk=0,mclk=0,pclk=0,mrun=1,prun=1;
 always #18.5 cclk=~cclk;
 always #4 if(mrun)mclk=~mclk;
 always #3.333 if(prun)pclk=~pclk;
 reg reset_n=0,video_lock=0,processing_lock=0,memory_lock=1;
 reg ready=0,fault=0,camera_lost=0;integer init_count=0,cases=0;
 wire joint,fabric,latched,armed,mreset,preset;
 processing_domain_reset dut(cclk,reset_n,video_lock,processing_lock,memory_lock,ready,fault,camera_lost,joint,fabric,latched,armed);
 reset_sync memory_release(mclk,fabric,mreset);
 reset_sync processing_release(pclk,fabric,preset);
 always @(posedge mclk or negedge joint)begin
  if(!joint)begin ready<=0;init_count<=0;end
  else if(init_count==30)ready<=1;
  else init_count<=init_count+1;
 end
 always @(posedge mclk or posedge pclk)begin
  #0.001;if((mreset || preset) && !armed)$fatal(1,"Business released before cold-reset arm");
 end
 task board_restart;
  begin
   reset_n=0;fault=0;camera_lost=0;video_lock=1;processing_lock=1;memory_lock=1;mrun=1;prun=1;
   #80;reset_n=1;wait(mreset && preset);#1;
   if(!joint || !fabric || !armed || latched)$fatal(1,"Cannot initialize after board reset");
  end
 endtask
 task quarantined;
  begin
   #0.01;if(joint || fabric || mreset || preset)$fatal(1,"Lost health did not assert common reset");
   repeat(10)@(negedge cclk);
   if(!latched || joint || fabric)$fatal(1,"Fault did not quarantine controller");
   video_lock=1;processing_lock=1;memory_lock=1;fault=0;camera_lost=0;mrun=1;prun=1;
   repeat(60)@(negedge mclk);
   if(joint || fabric || mreset || preset)$fatal(1,"Automatically restarted with stale native ownership");
   cases=cases+1;
  end
 endtask
 initial begin
  // Native initialization is permitted before processing PLL lock, while all
  // data clients remain reset. This explicitly tests absence of startup loops.
  #1;reset_n=0;#80;video_lock=1;reset_n=1;
  wait(ready);repeat(8)@(negedge cclk);
  if(!joint || fabric || armed)$fatal(1,"Processing lock startup deadlock or premature arm");
  processing_lock=1;wait(mreset && preset);cases=cases+1;
  // The same assertion must work when both client clocks have stopped.
  @(negedge mclk);mrun=0;@(negedge pclk);prun=0;processing_lock=0;quarantined;
  board_restart;memory_lock=0;quarantined;
  board_restart;video_lock=0;quarantined;
  board_restart;fault=1;wait(!joint);quarantined;
  board_restart;camera_lost=1;wait(!joint);quarantined;
  // A sub-control-cycle loss still resets native ready asynchronously. That
  // retained unready level is then synchronized and latched as a cold fault.
  board_restart;processing_lock=0;#0.01;processing_lock=1;quarantined;
  board_restart;
  $display("PROCESSING_RESET_PASS cases=%0d",cases);$finish;
 end
 initial begin #100000;$fatal(1,"Reset watchdog");end
endmodule
