`timescale 1ns/1ps
// Purpose: exercise the actual serial PC boot frame and independent serial
// reply decode. Runtime requests cannot overwrite the immutable boot entity.
module tb_pc_video_boot;
 reg clk=0,rst=0,serial_rx=1;always #4 clk=~clk;
 wire serial_tx,configured;wire [63:0] epoch;wire [47:0] lm,pm;wire [31:0] li,pi;wire [15:0] lp,pp;
 pc_video_boot #(.BAUD(12500000)) dut(.clk(clk),.rst_n(rst),.uart_rx(serial_rx),.uart_tx(serial_tx),
  .configured(configured),.epoch(epoch),.local_mac(lm),.peer_mac(pm),.local_ip(li),.peer_ip(pi),.local_port(lp),.peer_port(pp));
 wire reply_valid;wire [7:0] reply_byte;reg [7:0] received[0:83];integer replies=0;
 uart_8n1 #(.BAUD(12500000)) decode(.clk(clk),.rst_n(rst),.rx(serial_tx),.tx(),.rx_valid(reply_valid),.rx_data(reply_byte),
  .framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)if(reply_valid)begin received[replies]=reply_byte;replies=replies+1;end
 function [15:0] update(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer k;begin v=c^{b,8'd0};for(k=0;k<8;k=k+1)v=(v<<1)^(v[15]?16'h1021:0);update=v;end
 endfunction
 task byte_send(input [7:0] b);
  integer k;begin
   @(negedge clk);serial_rx=0;repeat(10)@(negedge clk);
   for(k=0;k<8;k=k+1)begin serial_rx=b[k];repeat(10)@(negedge clk);end
   serial_rx=1;repeat(12)@(negedge clk);
  end
 endtask
 reg [255:0] payload;reg [15:0] crc;reg [7:0] b;integer k;
 task request;
  begin
   byte_send(8'h55);byte_send(8'haa);crc=16'hffff;
   for(k=0;k<38;k=k+1)begin
    case(k)0:b=1;1:b=8'h71;2:b=9;3:b=0;4:b=32;5:b=0;default:b=payload[(k-6)*8+:8];endcase
    crc=update(crc,b);byte_send(b);
   end
   byte_send(crc[7:0]);byte_send(crc[15:8]);
  end
 endtask
 initial begin
  payload=256'hc350c3510350a8c00350a8c0030000000002010000000002fedcba9876543210;
  // Explicit wire order: source 02:00:00:00:00:01; peer ..:03; IPv4
  // 192.168.80.3 -> 192.168.80.2; ports 50001 -> 50000.
  payload[0+:64]=64'hfedcba9876543210;
  payload[64+:48]=48'h010000000002;payload[112+:48]=48'h030000000002;
  payload[160+:32]=32'h0350a8c0;payload[192+:32]=32'h0250a8c0;
  payload[224+:16]=50001;payload[240+:16]=50000;
  #100;rst=1;repeat(20)@(negedge clk);request;
  wait(configured);wait(replies==42);repeat(20)@(negedge clk);
  if(epoch!=64'hfedcba9876543210 || lm!=48'h020000000001 || pm!=48'h020000000003 || li!=32'hc0a85003 || pi!=32'hc0a85002 || lp!=50001 || pp!=50000)
   $fatal(1,"Boot entity differs from wire payload");
  if(received[3]!=8'h80 || received[4]!=9 || received[6]!=32 || received[8]!=0 || received[9]!=8'h71)$fatal(1,"Boot ACK fields");
  crc=16'hffff;for(k=2;k<40;k=k+1)crc=update(crc,received[k]);
  if({received[41],received[40]}!=crc)$fatal(1,"Boot ACK CRC");
  payload[63:0]=1;request;wait(replies==84);
  if(epoch!=64'hfedcba9876543210 || received[45]!=8'h81 || received[50]!=6)$fatal(1,"Runtime boot overwrite was allowed");
  $display("TB_PC_VIDEO_BOOT_PASS bytes=%0d",replies);$finish;
 end
 initial begin #3000000;$fatal(1,"PC boot timeout state=%0d bytes=%0d",dut.state,replies);end
endmodule
