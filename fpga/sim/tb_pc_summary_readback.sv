`timescale 1ns/1ps
// Exercise the actual serial compact profile: capability, frozen summaries,
// exact retries, page bounds, reset ownership and withdrawn upload kinds.
module tb_pc_summary_readback;
 reg clk=0,rst=0,rx=1;always #4 clk=~clk;
 wire tx,configured;reg [2303:0] status=0;wire [15:0] kind;
 pc_video_boot #(.BAUD(12500000),.ENTITY_MASK(16'h028a),.SUMMARY_READBACK(1),.STREAM_CCM(1)) dut(
  .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.configured(configured),
  .entity_status(status),.entity_read_kind(kind),.entity_submit_code(8'd0),
  .control_status(768'd0),.geometry_status(768'd0),.reference_status(768'd0),.affine_status(768'd0),
  .reference_submit_code(8'd0),.affine_submit_code(8'd0),.runtime_action_code(8'd6),
  .geometry_submit_ready(1'b1),.mode_submit_ready(1'b1));
 wire byte_valid;wire [7:0] byte_data;reg [7:0] response[0:2047];integer replies=0;
 uart_8n1 #(.BAUD(12500000)) decoder(.clk(clk),.rst_n(rst),.rx(tx),.tx(),
  .rx_valid(byte_valid),.rx_data(byte_data),.framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)if(byte_valid)begin response[replies]=byte_data;replies=replies+1;end
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};for(j=0;j<8;j=j+1)v=(v<<1)^(v[15]?16'h1021:0);crc_byte=v;end
 endfunction
 task send_byte(input [7:0] b);
  integer j;begin @(negedge clk);rx=0;repeat(10)@(negedge clk);
   for(j=0;j<8;j=j+1)begin rx=b[j];repeat(10)@(negedge clk);end
   rx=1;repeat(12)@(negedge clk);end
 endtask
 integer target=0;reg [15:0] sequence_override=0;
 task request(input [7:0] cmd,input integer length,input [639:0] data);
  reg [15:0] crc,seq;reg [7:0] b;integer j,base;
  begin target=target+1;seq=sequence_override?sequence_override:target;
   send_byte(8'h55);send_byte(8'haa);crc=16'hffff;
   for(j=0;j<length+6;j=j+1)begin
    case(j)0:b=1;1:b=cmd;2:b=seq[7:0];3:b=seq[15:8];4:b=length;5:b=0;default:b=data[(j-6)*8+:8];endcase
    crc=crc_byte(crc,b);send_byte(b);
   end
   send_byte(crc[7:0]);send_byte(crc[15:8]);wait(replies==target*42);repeat(20)@(negedge clk);
   // Every reply, including error and retry, must retain framing and CRC.
   base=(target-1)*42;crc=16'hffff;for(j=2;j<40;j=j+1)crc=crc_byte(crc,response[base+j]);
   if({response[base+41],response[base+40]}!==crc)$fatal(1,"reply CRC");
  end
 endtask
 task expect_code(input [7:0] code);
  begin if(response[(target-1)*42+8]!==code)$fatal(1,"code target=%0d got=%0d expected=%0d",target,response[(target-1)*42+8],code);end
 endtask
 reg [639:0] boot=0,payload;reg [255:0] frozen;integer j,k;
 initial begin
  boot[63:0]=99;boot[64+:48]=48'h010000000002;boot[112+:48]=48'h020000000002;
  boot[160+:32]=32'h0350a8c0;boot[192+:32]=32'h0250a8c0;boot[224+:16]=50001;boot[240+:16]=50000;
  #100;rst=1;repeat(20)@(negedge clk);request(8'h71,32,boot);wait(configured);
  request(8'ha0,1,0);expect_code(0);
  if(response[42+20]!=13 || {response[42+25],response[42+24]}!=16'h068a)$fatal(1,"compact capability mask");
  // Body is deliberately nonzero and must never appear as readable values.
  status={2304{1'b1}};status[255:0]={64'h1122334455667788,64'hfedcba9876543210,8'd0,8'd3,16'd64,32'd9,32'd8,16'd3,16'd1};
  frozen=status[255:0];frozen[15:0]=2;frozen[111:96]=0;
  request(8'ha4,4,3);expect_code(0);
  for(j=0;j<24;j=j+1)if(response[(target-1)*42+12+j]!==frozen[j*8+:8])$fatal(1,"summary page0");
  sequence_override=target;status=0;request(8'ha4,4,3);expect_code(0);sequence_override=0;
  for(j=0;j<24;j=j+1)if(response[(target-1)*42+12+j]!==frozen[j*8+:8])$fatal(1,"page0 retry not frozen");
  request(8'ha4,4,32'h00010003);expect_code(0);
  for(j=0;j<24;j=j+1)if(response[(target-1)*42+12+j] !== (j<8?frozen[(24+j)*8+:8]:8'd0))$fatal(1,"summary page1 or padding");
  request(8'ha4,4,32'h00020003);expect_code(11);
  // MCU pose, policy and motion diagnostic cannot be re-enabled by a packet.
  for(k=8;k<=12;k=k+1)if(k!=9 && k!=10)begin request(8'ha4,4,k);expect_code(11);end
  for(k=8;k<=12;k=k+4)begin
   payload=0;payload[15:0]=k;payload[31:16]=1;payload[63:32]=100+k;
   payload[95:64]=2;payload[127:96]=7;payload[143:128]=k==8?128:64;
   request(8'ha1,24,payload);expect_code(6);
  end
  // Reset revokes the snapshot even when stale payload bytes remain in RAM.
  rst=0;repeat(5)@(negedge clk);rst=1;request(8'h71,32,boot);wait(configured);
  request(8'ha4,4,32'h00010003);expect_code(11);
  $display("PC_SUMMARY_READBACK_PASS frozen pages retry reset capabilities withdrawn uploads");$finish;
 end
 initial begin #6000000;$fatal(1,"summary timeout");end
endmodule
