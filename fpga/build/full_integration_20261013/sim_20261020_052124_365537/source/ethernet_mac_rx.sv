`timescale 1ns/1ps
// Commit complete GMII RX bodies only after Ethernet CRC residue/length check.
// One bounded 2048B bank; while replay is stalled incoming frames are dropped
// whole and counted. ARP/control receive is low bandwidth, never backpressures
// physical RX. No Ethernet byte is marked good before its FCS is verified.
module ethernet_mac_rx(
 input clk,input rst_n,input link_up,input [7:0] rx_data,input rx_dv,rx_er,
 output out_valid,input out_ready,output reg [7:0] out_data,output out_last,
 output reg [31:0] good_frames,bad_frames,overruns
);
 localparam IDLE=0,PRE=1,BODY=2,DROP=3,REPLAY=4;
 reg [2:0] state;reg [3:0] pre_count;
 reg [10:0] count,pos,last_pos;reg [31:0] crc;reg bad;
 reg [7:0] mem [0:2047];
 assign out_valid=state==REPLAY;
 assign out_last=state==REPLAY && pos==last_pos;
 function automatic [31:0] update(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1) v=(v>>1)^(v[0]?32'hedb88320:0);update=v;end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;pre_count<=0;count<=0;pos<=0;last_pos<=0;crc<=0;bad<=0;out_data<=0;
   good_frames<=0;bad_frames<=0;overruns<=0;end
  else if(!link_up) state<=IDLE;
  else case(state)
   IDLE: if(rx_dv) begin
    pre_count<=1;
    if(rx_data==8'h55 && !rx_er) state<=PRE;else begin state<=DROP;bad_frames<=bad_frames+1;end
   end
   PRE: if(!rx_dv || rx_er) begin state<=DROP;bad_frames<=bad_frames+1;end
    else if(pre_count==7 && rx_data==8'hd5) begin state<=BODY;count<=0;crc<=32'hffffffff;bad<=0;end
    else if(pre_count<7 && rx_data==8'h55) pre_count<=pre_count+1'b1;
    else begin state<=DROP;bad_frames<=bad_frames+1;end
   BODY: if(rx_dv) begin
    if(count<1518) begin mem[count]<=rx_data;count<=count+1'b1;crc<=update(crc,rx_data);bad<=bad || rx_er;end
    else begin state<=DROP;bad_frames<=bad_frames+1;end
   end else if(!bad && count>=64 && crc==32'hdebb20e3) begin
    state<=REPLAY;pos<=0;last_pos<=count-5;out_data<=mem[0];good_frames<=good_frames+1;
   end else begin state<=IDLE;bad_frames<=bad_frames+1;end
   DROP: if(!rx_dv) state<=IDLE;
   REPLAY: begin
    // Physical ingress while replaying is a whole-frame overrun. Move to DROP
    // after replay completion if RX remains active, so its tail cannot be parsed.
    if(rx_dv && !bad) begin overruns<=overruns+1;bad<=1;end
    if(out_ready) begin
     if(out_last) begin state<=rx_dv ? DROP : IDLE;bad<=0;end
     else begin pos<=pos+1'b1;out_data<=mem[pos+1'b1];end
    end
   end
   default: state<=IDLE;
  endcase
 end
endmodule
