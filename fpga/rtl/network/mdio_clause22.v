`timescale 1ns/1ps
`default_nettype none
// Purpose: bounded Clause-22 MDIO transactions, including all 32 preamble bits.
// One system-clock domain; MDC is a registered output, never a fabric clock.
// At 125 MHz HALF_CYCLES=63 gives 504 ns per half-cycle. Capture the input
// synchronizer immediately BEFORE issuing each MDC rising edge: the PHY bit
// was launched after the previous rising edge (0..300 ns output delay), so
// it has a full 1008 ns period minus delay/synchronization to settle. Sampling
// at the end of high instead consumes the NEXT bit and shifts reads left.
module mdio_clause22 #(parameter integer HALF_CYCLES=63)(
 input wire clk,reset_n,start,read_not_write,
 input wire [4:0] phy_addr,reg_addr,input wire [15:0] write_data,
 input wire mdio_i,output wire mdio_o,mdio_oe,output reg mdc,
 output reg busy,done,ack_error,output reg [15:0] read_data
);
 localparam integer CW=(HALF_CYCLES<2)?1:$clog2(HALF_CYCLES);
 reg [CW-1:0] tick;
 reg [5:0] bit_index;
 reg [63:0] command;
 reg reading;
 // Purpose: only these two flops sample the asynchronous management input.
 (* syn_preserve=1, ASYNC_REG="TRUE" *) reg mdio_meta,mdio_sync;
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin mdio_meta<=1'b1;mdio_sync<=1'b1;end
  else begin mdio_meta<=mdio_i;mdio_sync<=mdio_meta;end
 end
 // Release the bus for BOTH read turnaround bits and all read data/idle.
 assign mdio_oe=busy && !(reading && bit_index<=17);
 assign mdio_o=command[63];
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   mdc<=0;busy<=0;done<=0;ack_error<=0;read_data<=0;
   tick<=0;bit_index<=0;command<=0;reading<=0;
  end else begin
   done<=0;
   if(!busy) begin
    mdc<=0;tick<=0;
    if(start) begin
     busy<=1;reading<=read_not_write;bit_index<=63;ack_error<=0;read_data<=0;
     command<={32'hffffffff,2'b01,(read_not_write?2'b10:2'b01),
               phy_addr,reg_addr,2'b10,write_data};
    end
   end else if(tick==HALF_CYCLES-1) begin
    tick<=0;mdc<=~mdc;
    if(!mdc) begin
     // TA0 is present before rising edge47, D15..D0 before edges48..63.
     // Use the system clock plus enable, not a new fabric MDC clock domain.
     if(reading && bit_index==16) ack_error<=mdio_sync;
     if(reading && bit_index<16) read_data<={read_data[14:0],mdio_sync};
    end else begin
     // Drive/advance host command bits at falling edges; retire after the
     // final high half-cycle so data/ACK are stable before asserting done.
     if(bit_index==0) begin busy<=0;done<=1;end
     else begin bit_index<=bit_index-1'b1;command<={command[62:0],1'b1};end
    end
   end else tick<=tick+1'b1;
  end
 end
endmodule
`default_nettype wire
