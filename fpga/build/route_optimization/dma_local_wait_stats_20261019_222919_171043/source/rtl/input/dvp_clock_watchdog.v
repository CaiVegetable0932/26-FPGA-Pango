`timescale 1ns/1ps
// 用途：在独立控制时钟域发现停止的 PCLK；PCLK 域计数器本身无法在停钟后发超时事件。
// 活动仅使用分频 toggle 同步，不跨域采样多位计数；这不是外部时钟频率/MTBF签核。
module dvp_clock_watchdog #(parameter DIV_BITS=8,parameter LOSS_CYCLES=270000)(
 input wire pclk,pclk_reset_n,ctrl_clk,ctrl_reset_n,enable,
 output reg clock_lost,output reg loss_event
);
 reg [DIV_BITS:0] activity;
 (* syn_preserve=1 *) reg meta,sync;
 reg previous;reg [31:0] idle_ticks;
 always @(posedge pclk or negedge pclk_reset_n)
  if(!pclk_reset_n)activity<=0;else activity<=activity+1'b1;
 always @(posedge ctrl_clk or negedge ctrl_reset_n)begin
  if(!ctrl_reset_n)begin meta<=0;sync<=0;previous<=0;idle_ticks<=0;clock_lost<=0;loss_event<=0;end
  else begin
   meta<=activity[DIV_BITS];sync<=meta;previous<=sync;loss_event<=0;
   if(!enable)begin idle_ticks<=0;clock_lost<=0;end
   else if(sync!=previous)begin idle_ticks<=0;clock_lost<=0;end
   else if(idle_ticks>=LOSS_CYCLES-1)begin
    if(!clock_lost)loss_event<=1;
    clock_lost<=1;
   end else idle_ticks<=idle_ticks+1'b1;
  end
 end
endmodule
