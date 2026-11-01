`timescale 1ns/1ps
// OV5640 v2.01 section 2.6 group0 transaction: preflight the fixed RAW mode,
// buffer only shutter/gain, end/launch, then read the actual latched registers.
// Completion proves register readback, never the exposure identity of a frame.
module ov5640_group_exposure #(parameter TIMEOUT=108000000)(
 input clk,rst_n,apply,input [19:0] exposure,input [9:0] gain,
 output apply_ready,output reg done,output reg [2:0] error,output busy,
 output reg cmd_valid,input cmd_ready,output reg cmd_write,
 output reg [15:0] cmd_addr,output reg [7:0] cmd_value,output [31:0] cmd_cookie,
 input rsp_valid,input [2:0] rsp_status,input [7:0] rsp_value,input [31:0] rsp_cookie
);
 localparam IDLE=0,SEND=1,WAIT=2;
 reg [1:0] state;reg [4:0] index;reg [31:0] deadline;
 reg [19:0] held_exposure;reg [9:0] held_gain;reg [7:0] high_exp,high_gain;
 assign apply_ready=state==IDLE && cmd_ready,busy=state!=IDLE;
 assign cmd_cookie={27'h6ca0000,index};
 // Raw writes are confined to indices10..17. Reserved exposure/gain bits
 // come from preflight reads, and no standby, timing, clock or VTS write exists.
 always @*begin
  cmd_write=index>=10 && index<=17;cmd_value=0;cmd_addr=0;
  case(index)
   0:cmd_addr=16'h3213;
   1:cmd_addr=16'h3503;
   2:cmd_addr=16'h3a00;
   3:cmd_addr=16'h350c;
   4:cmd_addr=16'h350d;
   5:cmd_addr=16'h5001;
   6:cmd_addr=16'h380e;
   7:cmd_addr=16'h380f;
   8:cmd_addr=16'h3500;
   9:cmd_addr=16'h350a;
   10:begin cmd_addr=16'h3212;cmd_value=0;end
   11,19:begin cmd_addr=16'h3500;cmd_value={high_exp[7:4],held_exposure[19:16]};end
   12,20:begin cmd_addr=16'h3501;cmd_value=held_exposure[15:8];end
   13,21:begin cmd_addr=16'h3502;cmd_value=held_exposure[7:0];end
   14,22:begin cmd_addr=16'h350a;cmd_value={high_gain[7:2],held_gain[9:8]};end
   15,23:begin cmd_addr=16'h350b;cmd_value=held_gain[7:0];end
   16:begin cmd_addr=16'h3212;cmd_value=8'h10;end
   17:begin cmd_addr=16'h3212;cmd_value=8'ha0;end
   18:cmd_addr=16'h3213;
  endcase
 end
 reg mismatch;
 always @*begin
  mismatch=0;
  case(index)
   0:mismatch=(rsp_value&8'h38)!=0;
   1:mismatch=(rsp_value&3)!=3;
   2:mismatch=(rsp_value&4)!=0;
   3,4:mismatch=rsp_value!=0;
   5:mismatch=(rsp_value&1)!=0;
   6:mismatch=rsp_value!=4;
   7:mismatch=rsp_value!=8'h60;
   18:mismatch=(rsp_value&8'h38)!=0;
   19,20,21,22,23:mismatch=rsp_value!=cmd_value;
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;index<=0;deadline<=0;held_exposure<=0;held_gain<=0;high_exp<=0;high_gain<=0;cmd_valid<=0;done<=0;error<=0;end
  else begin
   cmd_valid<=0;done<=0;
   if(state!=IDLE)deadline<=deadline+1'b1;else deadline<=0;
   if(state!=IDLE && deadline>=TIMEOUT-1)begin state<=IDLE;done<=1;error<=2;end
   else case(state)
    IDLE:if(apply && apply_ready)begin
     error<=0;
     if(exposure<16 || exposure>17856 || gain<16)begin done<=1;error<=5;end
     else begin held_exposure<=exposure;held_gain<=gain;index<=0;state<=SEND;end
    end
    SEND:if(cmd_ready)begin cmd_valid<=1;state<=WAIT;end
    WAIT:if(rsp_valid)begin
     if(rsp_status!=0 || rsp_cookie!=cmd_cookie)begin state<=IDLE;done<=1;error<=rsp_status!=0?rsp_status:3;end
     else if(index<10 && mismatch)begin state<=IDLE;done<=1;error<=3;end
     // Launch is asynchronous to SCCB. Poll the status and full readback until
     // the launched group latches, with the same transaction deadline.
     else if(index>=18 && mismatch)begin index<=18;state<=SEND;end
     else if(index==23)begin state<=IDLE;done<=1;end
     else begin
      if(index==8)high_exp<=rsp_value;
      if(index==9)high_gain<=rsp_value;
      index<=index+1'b1;state<=SEND;
     end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
