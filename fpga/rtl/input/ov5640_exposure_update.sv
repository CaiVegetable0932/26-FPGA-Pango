`timescale 1ns/1ps
// Reuse the sole SCCB register service after capture/queues drain. This is a
// stop-stream transaction, not 0x3212 group launch: the installed OV5640 v2.01
// datasheet does not prove a precise exposure-frame mapping for this board.
module ov5640_exposure_update #(parameter TIMEOUT=108000000)(
 input clk,rst_n,apply,quiesced,input [19:0] exposure,input [9:0] gain,
 output apply_ready,output reg done,output reg [2:0] error,output busy,
 output reg cmd_valid,input cmd_ready,output cmd_write,
 output reg [15:0] cmd_addr,output reg [7:0] cmd_value,cmd_mask,output [31:0] cmd_cookie,
 input rsp_valid,input [2:0] rsp_status,input [7:0] rsp_value,input [31:0] rsp_cookie
);
 localparam IDLE=0,SEND=1,WAIT=2;
 reg [1:0] state;reg [3:0] index;reg [19:0] held_exposure;reg [9:0] held_gain;reg [31:0] deadline;
 assign apply_ready=state==IDLE && cmd_ready,busy=state!=IDLE,cmd_write=1'b1;
 assign cmd_cookie={28'hca00000,index};
 // Every write is mask-preserving and read-verified by the shared service.
 // HTS/VTS and PLL are absent: AE cannot silently reduce the source cadence.
 always @*begin
  cmd_addr=0;cmd_value=0;cmd_mask=8'hff;
  case(index)
   0:begin cmd_addr=16'h3008;cmd_value=8'h40;cmd_mask=8'h40;end
   1:begin cmd_addr=16'h3503;cmd_value=3;cmd_mask=3;end
   2:begin cmd_addr=16'h3a00;cmd_value=0;cmd_mask=4;end
   3:cmd_addr=16'h350c;
   4:cmd_addr=16'h350d;
   5:begin cmd_addr=16'h3500;cmd_value={4'd0,held_exposure[19:16]};cmd_mask=15;end
   6:begin cmd_addr=16'h3501;cmd_value=held_exposure[15:8];end
   7:begin cmd_addr=16'h3502;cmd_value=held_exposure[7:0];end
   8:begin cmd_addr=16'h350a;cmd_value={6'd0,held_gain[9:8]};cmd_mask=3;end
   9:begin cmd_addr=16'h350b;cmd_value=held_gain[7:0];end
   10:begin cmd_addr=16'h3406;cmd_value=1;cmd_mask=1;end
   11:begin cmd_addr=16'h3008;cmd_value=0;cmd_mask=8'h40;end
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;index<=0;held_exposure<=0;held_gain<=0;deadline<=0;cmd_valid<=0;done<=0;error<=0;end
  else begin
   done<=0;cmd_valid<=0;
   if(state!=IDLE)deadline<=deadline+1'b1;else deadline<=0;
   if(state!=IDLE && (!quiesced || deadline>=TIMEOUT-1))begin state<=IDLE;done<=1;error<=!quiesced?6:2;end
   else case(state)
    IDLE:if(apply && apply_ready)begin
     error<=0;
     if(!quiesced)begin done<=1;error<=6;end
     else if(exposure<16 || exposure>17856 || gain<16)begin done<=1;error<=5;end
     else begin held_exposure<=exposure;held_gain<=gain;index<=0;state<=SEND;end
    end
    SEND:if(cmd_ready)begin cmd_valid<=1;state<=WAIT;end
    WAIT:if(rsp_valid)begin
     if(rsp_status!=0 || rsp_cookie!=cmd_cookie || (rsp_value&cmd_mask)!=(cmd_value&cmd_mask))begin
      state<=IDLE;done<=1;error<=rsp_status!=0?rsp_status:3;
     end else if(index==11)begin state<=IDLE;done<=1;end
     else begin index<=index+1'b1;state<=SEND;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
