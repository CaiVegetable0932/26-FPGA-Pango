`timescale 1ns/1ps
// Packet-granularity arbitration: main stream gets 8 grants before one pending
// control grant. No preemption inside a packet. Control cannot starve RAW, and
// continuous RAW cannot starve ARP. Both inputs must be complete buffered bodies.
module ethernet_packet_mux(
 input clk,input rst_n,input cancel_raw,
 input raw_valid,output raw_ready,input [7:0] raw_data,input raw_last,
 input control_valid,output control_ready,input [7:0] control_data,input control_last,
 output out_valid,input out_ready,output [7:0] out_data,output out_last,
 output raw_selected
);
 localparam IDLE=0,RAW=1,CONTROL=2;
 reg [1:0] state;reg [3:0] raw_grants;
 assign raw_selected=state==RAW;
 assign raw_ready=state==RAW && out_ready && !cancel_raw;
 assign control_ready=state==CONTROL && out_ready;
 assign out_valid=(state==RAW)?(raw_valid && !cancel_raw):(state==CONTROL && control_valid);
 assign out_data=(state==RAW)?raw_data:control_data;
 assign out_last=(state==RAW)?raw_last:control_last;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;raw_grants<=0;end
  else if(state==RAW && cancel_raw) state<=IDLE;
  else if(state==IDLE) begin
   if(control_valid && (!raw_valid || raw_grants==8)) begin state<=CONTROL;raw_grants<=0;end
   else if(raw_valid) begin state<=RAW;if(raw_grants<8) raw_grants<=raw_grants+1'b1;end
  end else if(out_valid && out_ready && out_last) state<=IDLE;
 end
endmodule
