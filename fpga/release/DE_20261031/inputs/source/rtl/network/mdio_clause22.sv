`timescale 1ns/1ps
// Bounded IEEE Clause 22 management transaction, full 32-bit preamble.
// Output changes on MDC falling edges, input sampled on rising edges. MDIO
// read turnaround releases the line for both TA bits and requires PHY zero.
// MDC=CLK_HZ/(2*HALF_PERIOD), default <=2.5MHz. IO tri-state belongs at board IO.
// Register/page programming is NOT guessed; caller supplies verified PHY config.
module mdio_clause22 #(parameter HALF_PERIOD=25)(
 input clk,input rst_n,input request_valid,output request_ready,
 input request_read,input [4:0] phy_addr,reg_addr,input [15:0] write_data,
 output reg mdc,output mdio_o,output mdio_oe,input mdio_i,
 output reg response_valid,input response_ready,output reg [15:0] read_data,
 output reg turnaround_error
);
 reg active,is_read;reg [63:0] bits;reg [6:0] pos;integer divider;
 assign request_ready=!active && !response_valid;
 assign mdio_o=bits[63-pos];
 assign mdio_oe=active && (!is_read || pos<46);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active<=0;is_read<=0;bits<=64'hffffffffffffffff;pos<=0;divider<=0;
   mdc<=0;response_valid<=0;read_data<=0;turnaround_error<=0;end
  else begin
   if(response_valid && response_ready) response_valid<=0;
   if(request_valid && request_ready) begin
    bits<={32'hffffffff,2'b01,(request_read?2'b10:2'b01),phy_addr,reg_addr,2'b10,write_data};
    is_read<=request_read;active<=1;pos<=0;divider<=HALF_PERIOD-1;mdc<=0;
    turnaround_error<=0;read_data<=0;
   end else if(active) begin
    if(divider!=0) divider<=divider-1;
    else begin
     divider<=HALF_PERIOD-1;mdc<=!mdc;
     if(!mdc) begin
      if(is_read && pos==47 && mdio_i!=0) turnaround_error<=1;
      if(is_read && pos>=48) read_data<={read_data[14:0],mdio_i};
     end else begin
      if(pos==63) begin active<=0;response_valid<=1;end else pos<=pos+1'b1;
     end
    end
   end
  end
 end
endmodule
