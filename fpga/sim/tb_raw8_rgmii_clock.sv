`timescale 1ns/1ps
// Purpose: native ODDR check for RAW8's free-running, unshifted TXC. Local
// reset must blank data/control WITHOUT stopping the PHY reference clock.
module tb_raw8_rgmii_clock;
 reg clk=0,rst_n=0,grs_n=0;reg [7:0] data=0;reg en=0,er=0;
 wire txc,ctl;wire [3:0] pins;
 reg [7:0] expected=0;reg expected_en=0,expected_er=0;
 integer checks=0,i,c;real previous_rise=0;integer edges=0;
 always #4 clk=~clk;
 GTP_GRS GRS_INST(.GRS_N(grs_n));
 pango_rgmii_tx #(.PHY_TXID(1),.SEPARATE_TXC_RESET(1)) dut(
  .clk125(clk),.clk125_90(clk),.reset_n(rst_n),.txc_reset_n(1'b1),
  .gmii_data(data),.gmii_en(en),.gmii_error(er),
  .rgmii_txc(txc),.rgmii_ctl(ctl),.rgmii_data(pins));
 task check(input bit value,input string why);
  begin checks=checks+1;if(!value)$fatal(1,"RAW8_RGMII_FAIL %s",why);end
 endtask
 // Continuous physical-pin edge measurement includes every local reset pulse.
 always @(posedge txc)if(grs_n)begin
  if(edges!=0)check($realtime-previous_rise==8.0,"TXC period/reset continuity");
  check(clk===1'b1,"TXC has no FPGA phase shift; PHY adds TXID");
  previous_rise=$realtime;edges=edges+1;
 end
 task send(input [7:0] value,input bit txen,input bit txer);
  begin
   data=value;en=txen;er=txer;
   @(posedge clk);#0.1;
   check(pins===expected[3:0] && ctl===expected_en,"low nibble/control");
   check(txc===1'b1,"TXC rising");
   @(negedge clk);#0.1;
   check(pins===expected[7:4] && ctl===(expected_en^expected_er),"high nibble/control");
   check(txc===1'b0,"TXC falling");
   expected=value;expected_en=txen;expected_er=txer;
  end
 endtask
 initial begin
  #13;grs_n=1;repeat(5)@(negedge clk);#0.1;rst_n=1;
  for(c=0;c<4;c=c+1)begin
   for(i=0;i<256;i=i+1)send(i[7:0],c[0],c[1]);
   send(0,0,0);send(0,0,0);
   // Assert reset between clock edges, then observe several complete clocks.
   #1;rst_n=0;#0.1;check({pins,ctl}===5'b0,"asynchronous data reset");
   repeat(4)begin
    @(posedge clk);#0.1;check(txc===1'b1 && {pins,ctl}===5'b0,"clock during reset high");
    @(negedge clk);#0.1;check(txc===1'b0 && {pins,ctl}===5'b0,"clock during reset low");
   end
   rst_n=1;expected=0;expected_en=0;expected_er=0;
  end
  check(edges>1024,"full coverage clock count");
  $display("RAW8_RGMII_CLOCK_PASS checks=%0d vectors=1024 resets=4",checks);$finish;
 end
 initial begin #100000;$fatal(1,"RAW8_RGMII_TIMEOUT");end
endmodule
