`timescale 1ns/1ps
// Purpose: verify passive geometry flags using valid, short and partial frames.
module tb_mini_dvp_observe;
 reg clk=0,rst_n=0,vs=0,href=0;
 wire [3:0] seen;
 always #5 clk=~clk;
 mini_dvp_observe #(.WIDTH_BYTES(8),.HEIGHT(2)) dut(clk,rst_n,vs,href,seen);
 task tick(input bit v,input bit h);
  begin @(negedge clk);vs=v;href=h;@(posedge clk);#1;end
 endtask
 task line(input integer n);
  begin repeat(n) tick(0,1);repeat(3)tick(0,0);end
 endtask
 initial begin
  repeat(3)tick(0,0);rst_n=1;
  line(8);tick(1,0);if(seen[3])$fatal(1,"OBSERVE_FAIL partial frame");
  tick(0,0);line(7);line(8);tick(1,0);
  if(seen!==4'b0111)$fatal(1,"OBSERVE_FAIL short line");
  tick(0,0);line(8);line(8);tick(1,0);
  if(seen!==4'b1111)$fatal(1,"OBSERVE_FAIL valid geometry");
  rst_n=0;tick(0,0);if(seen!==0)$fatal(1,"OBSERVE_FAIL reset");
  $display("DVP_OBSERVE_PASS");$finish;
 end
 initial begin #10000;$fatal(1,"OBSERVE_TIMEOUT");end
endmodule
