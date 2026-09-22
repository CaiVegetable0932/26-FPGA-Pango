`timescale 1ns/1ps
`default_nettype none
// Purpose: MINI RTL8211F bring-up with verified TX clock-delay policy.
// PHY_TX_DELAY selects the audited board policy: 0 for a +2 ns MAC clock,
// 1 for an unshifted MAC clock. RMW and exact readback prevent double delay.
// Advertise only 1000/full, no PAUSE and no EEE (neither is implemented by
// this TX-only MAC). Any MDIO/ID/readback error latches a fail-closed fault.
// RTL8211F Rev1.4 section 7.17 and 9.3 note6 require 50 ms settling plus
// a reserved 100 ms configuration window unless explicitly skipped. Wait
// 200 ms after reset release; do not race boot or write the skip register.
// Hardware reset is >=10 ms. Link status
// is polled every 100 ms. A cable/link change is not an initialization fault.
module rtl8211f_init #(
 parameter integer CLK_HZ=125000000, HALF_CYCLES=63,
 parameter integer RESET_MS=10, SETTLE_MS=200, POLL_MS=100,
 parameter [4:0] PHY_ADDR=5'd1,
 parameter integer SCAN_ADDRESSES=0,
 parameter integer PHY_TX_DELAY=0
)(input wire clk,reset_n,mdio_i,output wire mdio_o,mdio_oe,mdc,
 output reg phy_reset_n,configured,link_ready,fault,
 output reg [3:0] fault_code,output reg [15:0] phy_status,
 output reg [31:0] phy_id,output reg [4:0] selected_addr,
 output wire [5:0] diagnostic_step,output reg [15:0] last_read,
 output reg last_ack_error);
 localparam integer MS_DIV=CLK_HZ/1000;
 localparam integer MS_CW=(MS_DIV<2)?1:$clog2(MS_DIV);
 reg [MS_CW-1:0] ms_divider;
 reg [15:0] wait_ms;
 reg [2:0] state;
 localparam HOLD=0,SETTLE=1,ISSUE=2,WAIT=3,POLL=4,FAILED=5;
 reg [5:0] step;
 reg start;
 wire busy,done,ack_error;
 wire [15:0] rdata;
 reg [15:0] saved;
 reg rd;
 reg [4:0] addr;
 reg [15:0] wdata;
 mdio_clause22 #(.HALF_CYCLES(HALF_CYCLES)) u_mdio(
  .clk(clk),.reset_n(reset_n),.start(start),.read_not_write(rd),
  .phy_addr(selected_addr),.reg_addr(addr),.write_data(wdata),.mdio_i(mdio_i),
  .mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(mdc),.busy(busy),.done(done),
  .ack_error(ack_error),.read_data(rdata));
 // Purpose: read-only discovery tries non-broadcast RTL8211F addresses 1..7.
 // No register is written until BOTH identifier words match the expected PHY.
 // Diagnostic outputs retain the last read and failing step even in FAILED.
 assign diagnostic_step=step;
 // Purpose: explicit transaction ROM; no broadcast writes or hidden defaults.
 // Steps 14..19 use IEEE MMD access to disable and read back EEE advertisement.
 always @* begin
  rd=0;addr=31;wdata=0;
  case(step)
   0: begin rd=1;addr=2;end
   1: begin rd=1;addr=3;end
   2: wdata=16'h0d08;
   3: begin rd=1;addr=17;end
   4: begin addr=17;wdata=(saved & 16'hfeff)|(PHY_TX_DELAY?16'h0100:16'h0000);end
   5: begin rd=1;addr=17;end
   6: wdata=0;
   7: begin rd=1;addr=4;end
   8: begin addr=4;wdata=(saved & 16'hf01f)|16'h0001;end
   9: begin rd=1;addr=4;end
   10: begin rd=1;addr=9;end
   11: begin addr=9;wdata=(saved & 16'hfeff)|16'h0200;end
   12: begin rd=1;addr=9;end
   13: begin addr=13;wdata=7;end
   14: begin addr=14;wdata=16'h003c;end
   15: begin addr=13;wdata=16'h4007;end
   16: begin addr=14;wdata=0;end
   17: begin rd=1;addr=14;end
   18: begin rd=1;addr=0;end
   // Clear power-down/isolate/loopback, then enable and restart negotiation.
   19: begin addr=0;wdata=(saved & 16'h33ff)|16'h1200;end
   20: wdata=16'h0a43;
   21: begin rd=1;addr=26;end
   22: wdata=0;
   default: begin rd=1;addr=2;end
  endcase
 end
 // Purpose: deterministic wait/start/completion sequencing, independently
 // checking each read's turnaround acknowledgment before trusting any data.
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   ms_divider<=0;wait_ms<=0;state<=HOLD;step<=0;start<=0;saved<=0;
   phy_reset_n<=0;configured<=0;link_ready<=0;fault<=0;fault_code<=0;
   phy_status<=0;phy_id<=0;
   selected_addr<=SCAN_ADDRESSES?5'd1:PHY_ADDR;last_read<=0;last_ack_error<=0;
  end else begin
   start<=0;
   if(ms_divider==MS_DIV-1) ms_divider<=0;else ms_divider<=ms_divider+1'b1;
   case(state)
    HOLD: if(ms_divider==MS_DIV-1) begin
     if(wait_ms==RESET_MS-1) begin wait_ms<=0;phy_reset_n<=1;state<=SETTLE;end
     else wait_ms<=wait_ms+1'b1;
    end
    SETTLE: if(ms_divider==MS_DIV-1) begin
     if(wait_ms==SETTLE_MS-1) begin wait_ms<=0;state<=ISSUE;end
     else wait_ms<=wait_ms+1'b1;
    end
    ISSUE: if(!busy) begin start<=1;state<=WAIT;end
    WAIT: if(done) begin
     if(rd) begin last_read<=rdata;last_ack_error<=ack_error;end
     if(ack_error && step==0 && SCAN_ADDRESSES && selected_addr<7) begin
      selected_addr<=selected_addr+1'b1;state<=ISSUE;
     end else if(ack_error) begin fault<=1;fault_code<=1;state<=FAILED;link_ready<=0;end
     else if((step==0 && rdata!=16'h001c) ||
             (step==1 && (rdata & 16'hfff0)!=16'hc910)) begin
      fault<=1;fault_code<=2;state<=FAILED;
     end else if((step==5 && rdata!=((saved & 16'hfeff)|(PHY_TX_DELAY?16'h0100:16'h0000))) ||
                 (step==9 && rdata!=((saved & 16'hf01f)|16'h0001)) ||
                 (step==12 && rdata!=((saved & 16'hfeff)|16'h0200)) ||
                 (step==17 && rdata!=0)) begin
      fault<=1;fault_code<=3;state<=FAILED;
     end else begin
      if(step==0) phy_id[31:16]<=rdata;
      if(step==1) phy_id[15:0]<=rdata;
      if(step==3 || step==7 || step==10 || step==18) saved<=rdata;
      if(step==21) begin
       phy_status<=rdata;link_ready<=rdata[2] && rdata[3] && rdata[5:4]==2'b10;
      end
      if(step==22) begin configured<=1;wait_ms<=0;ms_divider<=0;state<=POLL;end
      else begin step<=step+1'b1;state<=ISSUE;end
     end
    end
    POLL: if(ms_divider==MS_DIV-1) begin
     if(wait_ms==POLL_MS-1) begin step<=20;wait_ms<=0;state<=ISSUE;end
     else wait_ms<=wait_ms+1'b1;
    end
    FAILED: begin configured<=0;link_ready<=0;end
    default: begin fault<=1;fault_code<=4;state<=FAILED;end
   endcase
  end
 end
endmodule
`default_nettype wire
