`timescale 1ns/1ps
// Independent firmware vectors exercise fragmented input, payload magic,
// nested valid frame after bad CRC, length/version errors, absolute deadlines,
// and bounded overflow. Payload port is read and compared byte-for-byte.
module tb_uart_v2_parser;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,byte_valid=0,byte_error=0;reg [7:0] byte_data=0;
 reg [63:0] now_us=64'h00000007fffffff0;always @(posedge clk) now_us<=now_us+1;
 wire packet_valid,read_response;reg packet_ready=0,read_valid=0;
 reg [9:0] read_index=0;wire [7:0] read_data,cmd;wire [15:0] seq,length;
 wire [31:0] bad_crc,bad_header,timeouts,overflows;wire [11:0] peak;
 reg [7:0] vector [0:2047];reg [7:0] golden [0:105];
 integer i,k;wire [63:0] receive_us;
 uart_v2_parser #(.TIMEOUT_US(10000)) dut(.*,.peak_bytes(peak));
 task send(input [7:0] b);
  begin @(negedge clk);byte_data=b;byte_valid=1;@(negedge clk);byte_valid=0;repeat(3) @(negedge clk);end
 endtask
 task check_state;
  begin
   wait(packet_valid);
   if(cmd!=8'h81 || seq!=7 || length!=96) $fatal(1,"STATE header");
   for(k=0;k<96;k=k+1) begin
    @(negedge clk);read_index=k;read_valid=1;@(negedge clk);read_valid=0;
    if(!read_response || read_data!==golden[k+8]) $fatal(1,"STATE payload %0d",k);
   end
   @(negedge clk);packet_ready=1;@(negedge clk);packet_ready=0;
  end
 endtask
 initial begin
  $readmemh("state.hex",golden);
  repeat(5) @(negedge clk);rst_n=1;
  send(8'h77);send(8'h55);send(8'h55);
  for(i=1;i<106;i=i+1) send(golden[i]);check_state();
  $readmemh("nested_bad_crc.hex",vector,0,122);
  for(i=0;i<123;i=i+1) send(vector[i]);check_state();
  $readmemh("bad_length_then_state.hex",vector,0,113);
  for(i=0;i<114;i=i+1) send(vector[i]);check_state();
  $readmemh("bad_version_then_state.hex",vector,0,113);
  for(i=0;i<114;i=i+1) send(vector[i]);check_state();
  $readmemh("payload_magic.hex",vector,0,17);
  for(i=0;i<18;i=i+1) send(vector[i]);wait(packet_valid);
  if(cmd!=8'h80 || length!=8 || seq!=5) $fatal(1,"payload magic restarted candidate");
  @(negedge clk);packet_ready=1;@(negedge clk);packet_ready=0;
  send(8'h55);send(8'haa);repeat(10010) @(negedge clk);
  for(i=0;i<106;i=i+1) send(golden[i]);check_state();
  // Leave a committed frame unacknowledged and saturate incoming ring.
  for(i=0;i<106;i=i+1) send(golden[i]);wait(packet_valid);
  for(i=0;i<2100;i=i+1) send(8'h33);
  for(i=0;i<106;i=i+1) send(golden[i]);check_state();
  if(bad_crc<1 || bad_header<2 || timeouts<1 || overflows<1 || peak!=2048) $fatal(1,"error counters");
  $display("UART_V2_PARSER_PASS crc=%0d header=%0d timeout=%0d overflow=%0d peak=%0d",bad_crc,bad_header,timeouts,overflows,peak);$finish;
 end
 initial begin #2000000;$fatal(1,"parser timeout");end
endmodule
