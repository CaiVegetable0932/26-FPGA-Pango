`timescale 1ns/1ps
import frame_manager_pkg::*;
module tb_pool_random;
 parameter integer SLOTS=3,TXNS=3;
 reg clk=0,reset_n=0,fabric_ready=0,display_boundary=0;
 frame_cmd_t cmd;frame_rsp_t rsp;integer seed=177,i,b;
 always #5 clk=~clk;
 frame_pool_bank #(.SLOTS(SLOTS),.TXNS(TXNS)) dut(clk,reset_n,fabric_ready,display_boundary,cmd,rsp);
 initial begin
  if($value$plusargs("SEED=%d",seed))begin end
  cmd='0;repeat(3)@(negedge clk);reset_n=1;
  for(i=0;i<30000;i=i+1)begin
   @(negedge clk);
   for(b=0;b<$bits(cmd);b=b+32)cmd[b+:32]=$random(seed);
   // Mix malformed/concurrent requests with legal zero-command drain edges.
   if((i%4)==0)cmd='0;
   fabric_ready=($random(seed)&7)!=0;display_boundary=($random(seed)&15)==0;
   reset_n=(i%601)!=0;
  end
  @(negedge clk);cmd='0;reset_n=1;repeat(5)@(negedge clk);
  $display("POOL_RANDOM_PASS");$finish;
 end
endmodule
