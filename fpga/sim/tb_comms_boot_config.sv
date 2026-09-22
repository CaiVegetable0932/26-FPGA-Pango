`timescale 1ns/1ps
// Purpose: independent UART receiver/CRC checker for the commissioning gateway.
// Accelerated divider=10 validates envelope rejection, byte order, immutable
// commit and full final-stop-bit mux handover without touching a physical UART.
// Purpose: exercise TEST and RAW8 profiles with identical rejection/CRC cases.
module tb_comms_boot_config #(parameter RAW_PROFILE=0);
 localparam [7:0] COMMAND=RAW_PROFILE?8'h71:8'h70;
 localparam [31:0] MARKER=RAW_PROFILE?32'h38574152:32'h54534554;
 reg clk=0;always #4 clk=~clk;
 reg rst=0,rx=1,emulator_tx=1;wire tx,configured;
 wire [63:0] epoch;wire [47:0] smac,dmac;wire [31:0] sip,dip;wire [15:0] sport,dport;
 comms_boot_config #(.CLK_HZ(1152000),.BOOT_COMMAND(COMMAND),.BOOT_MARKER(MARKER)) dut(.clk(clk),.reset_n(rst),.uart_rx(rx),
  .mcu_tx(emulator_tx),.uart_tx(tx),.configured(configured),.epoch(epoch),
  .src_mac(smac),.dst_mac(dmac),.src_ip(sip),.dst_ip(dip),.src_port(sport),.dst_port(dport));
 reg [255:0] cfg;reg [7:0] received[0:41];reg [7:0] rb;
 integer replies=0,index=0,checks=0,bit_i;reg [15:0] cr;
 function [15:0] crc(input [15:0] prior,input [7:0] b);
  integer j;reg [15:0] c;begin c=prior^{b,8'd0};for(j=0;j<8;j=j+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc=c;end
 endfunction
 task check(input bit ok,input string why);begin checks=checks+1;if(!ok)$fatal(1,"BOOT_FAIL %s",why);end endtask
 // Decode line levels independently, including every final stop bit.
 always begin
  @(negedge tx);if(rst&&!configured)begin
   #120;for(bit_i=0;bit_i<8;bit_i=bit_i+1)begin rb[bit_i]=tx;#80;end
   check(tx===1,"truncated stop bit");received[index]=rb;
   if(index==41)begin
    check(received[0]==8'h55 && received[1]==8'haa && received[2]==1,"ACK envelope");
    cr=16'hffff;for(index=2;index<40;index=index+1)cr=crc(cr,received[index]);
    check({received[41],received[40]}==cr,"ACK CRC");
    replies=replies+1;index=0;
   end else index=index+1;
  end
 end
 task put(input [7:0] b);
  integer j;begin rx=0;#80;for(j=0;j<8;j=j+1)begin rx=b[j];#80;end rx=1;#80;end
 endtask
 task send(input [7:0] cmd,input integer len,input bit corrupt,input [7:0] expected);
  reg [15:0] c;integer j,target;
  begin
   target=replies+1;c=16'hffff;
   put(8'h55);put(8'haa);put(1);c=crc(c,1);put(cmd);c=crc(c,cmd);
   put(8'h34);c=crc(c,8'h34);put(8'h12);c=crc(c,8'h12);
   put(len);c=crc(c,len);put(0);c=crc(c,0);
   for(j=0;j<len;j=j+1)begin put(cfg[j*8+:8]);c=crc(c,cfg[j*8+:8]);end
   put(c[7:0]^(corrupt?8'd1:8'd0));put(c[15:8]);
   wait(replies==target);check(received[8]==expected,$sformatf("reply code got=%0d expected=%0d",received[8],expected));
   check(received[4]==8'h34 && received[5]==8'h12,"sequence echo");#3000;
  end
 endtask
 initial begin
  #40;rst=1;#1000;
  cfg={16'd50000,16'd50001,32'h6401a8c0,32'h3201a8c0,
       48'h020000000002,48'h010000000002,64'h0102030405060708};
  send(8'h01,0,0,6);check(!configured,"unsupported command committed");
  send(RAW_PROFILE?8'h70:8'h71,32,0,6);check(!configured,"wrong image profile committed");
  send(COMMAND,31,0,3);check(!configured,"short configuration committed");
  send(COMMAND,32,1,2);check(!configured,"bad CRC committed");
  cfg[63:0]=0;send(COMMAND,32,0,11);check(!configured,"zero epoch committed");
  cfg[63:0]=64'h0102030405060708;cfg[64]=1;send(COMMAND,32,0,11);
  check(!configured,"multicast source committed");cfg[64]=0;
  send(COMMAND,32,0,0);wait(configured);
  check({received[31],received[30],received[29],received[28]}==MARKER,"image profile ACK marker");
  check(epoch==64'h0102030405060708 && smac==48'h020000000001 && dmac==48'h020000000002,
        "epoch/MAC byte order");
  check(sip==32'hc0a80132 && dip==32'hc0a80164 && sport==50001 && dport==50000,"IP/port byte order");
  emulator_tx=0;#100;check(tx==0,"UART handover");emulator_tx=1;
  cfg[63:0]=7;put(8'h55);put(8'haa);#1000;check(epoch==64'h0102030405060708,"immutable configuration");
  rst=0;#40;check(!configured && epoch==0,"reset clears commissioning");
  $display("COMMS_BOOT_PASS checks=%0d replies=%0d",checks,replies);$finish;
 end
 initial begin #2000000;$fatal(1,"BOOT_TIMEOUT");end
endmodule
