`timescale 1ns/1ps
// 用途：控制域在PCLK停钟后仍能超时，恢复活动/禁用时清状态，事件只脉冲一次。
module tb_dvp_clock_watchdog;
 reg ctrl=0,pclk=0,rst_n=0,run=1,enable=0;always #5 ctrl=~ctrl;
 always #3 if(run)pclk=~pclk;
 wire lost,event_loss;integer events=0;
 dvp_clock_watchdog #(.DIV_BITS(2),.LOSS_CYCLES(30)) dut(pclk,rst_n,ctrl,rst_n,enable,lost,event_loss);
 always @(posedge ctrl)begin #1;if(event_loss)events=events+1;end
 initial begin
 repeat(5)@(negedge ctrl);rst_n=1;enable=1;repeat(60)@(negedge ctrl);
 if(lost || events)$fatal(1,"WATCHDOG_FALSE_LOSS");
 run=0;repeat(60)@(negedge ctrl);if(!lost || events!=1)$fatal(1,"WATCHDOG_LOSS_FAIL");
 repeat(60)@(negedge ctrl);if(events!=1)$fatal(1,"WATCHDOG_REPEATED_EVENT");
 run=1;repeat(30)@(negedge ctrl);if(lost)$fatal(1,"WATCHDOG_RECOVERY_FAIL");
 run=0;enable=0;repeat(60)@(negedge ctrl);if(lost)$fatal(1,"WATCHDOG_DISABLED_FAIL");
 $display("DVP_CLOCK_WATCHDOG_PASS");$finish;
 end
 initial begin #100000;$fatal(1,"DVP_CLOCK_WATCHDOG_TIMEOUT");end
endmodule
