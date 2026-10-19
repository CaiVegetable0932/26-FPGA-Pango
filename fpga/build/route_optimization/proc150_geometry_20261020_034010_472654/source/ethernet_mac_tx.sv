`timescale 1ns/1ps
// GMII transmit-only MAC: 7B preamble, SFD, buffered body, minimum frame
// padding, independent Ethernet FCS, and 12B IFG. Source must have the COMPLETE
// frame committed before valid; after start it must supply one byte per cycle.
// Loss of valid aborts with TX_ER and increments underrun; never emits old bytes.
module ethernet_mac_tx(
 input clk,input rst_n,input link_up,
 input in_valid,output in_ready,input [7:0] in_data,input in_last,
 output reg [7:0] tx_data,output reg tx_en,tx_er,
 output idle,output reg [31:0] frames,underruns
);
 localparam IDLE=0,PRE=1,BODY=2,PAD=3,FCS=4,GAP=5;
 reg [2:0] state; reg [3:0] count; reg [10:0] body_bytes;
 reg [31:0] crc,fcs;
 assign idle=state==IDLE;
 assign in_ready=state==BODY && link_up;
 function automatic [31:0] update_crc(input [31:0] c,input [7:0] b);
  reg [31:0] v; integer i;
  begin v=c^b; for(i=0;i<8;i=i+1) v=(v>>1)^(v[0]?32'hedb88320:0); update_crc=v; end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;count<=0;body_bytes<=0;crc<=0;fcs<=0;
   tx_data<=0;tx_en<=0;tx_er<=0;frames<=0;underruns<=0;end
  else begin
   tx_en<=0;tx_er<=0;
   if(!link_up) begin
    if(state!=IDLE && state!=GAP) begin tx_er<=1;underruns<=underruns+1;end
    state<=IDLE;
   end else case(state)
    IDLE: if(in_valid) begin state<=PRE;count<=0;crc<=32'hffffffff;body_bytes<=0;end
    PRE: begin
     tx_en<=1;tx_data<=(count==7)?8'hd5:8'h55;
     if(count==7) state<=BODY; else count<=count+1'b1;
    end
    BODY: if(!in_valid) begin tx_en<=1;tx_er<=1;underruns<=underruns+1;state<=GAP;count<=0;end
     else begin
      tx_en<=1;tx_data<=in_data;crc<=update_crc(crc,in_data);body_bytes<=body_bytes+1'b1;
      if(in_last) begin
       if(body_bytes<59) state<=PAD;
       else begin fcs<=~update_crc(crc,in_data);state<=FCS;count<=0;end
      end
     end
    PAD: begin
     tx_en<=1;tx_data<=0;crc<=update_crc(crc,0);body_bytes<=body_bytes+1'b1;
     if(body_bytes==59) begin fcs<=~update_crc(crc,0);state<=FCS;count<=0;end
    end
    FCS: begin
     tx_en<=1;tx_data<=fcs[count*8+:8];
     if(count==3) begin state<=GAP;count<=0;frames<=frames+1;end else count<=count+1'b1;
    end
    GAP: if(count==11) state<=IDLE; else count<=count+1'b1;
    default: state<=IDLE;
   endcase
  end
 end
endmodule
