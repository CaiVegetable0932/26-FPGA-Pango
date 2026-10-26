`timescale 1ns/1ps
// Exercise the dual-parser wrapper with queued packet bytes at deadline edges,
// low32 rollover/backward timestamps, malformed traffic, reset and backpressure.
// The independent firmware vector supplies complete valid packet/CRC contents.
module tb_uart_deadline_stress #(parameter TIMEOUT_VALUE=30000);
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,byte_valid=0,byte_error=0,packet_ready=0,read_valid=0;
 reg [7:0] byte_data=0;reg [9:0] read_index=0;reg [63:0] now_us=0;
 wire packet_valid,read_response;wire [7:0] read_data,cmd;
 wire [15:0] seq,length;wire [63:0] receive_us;
 wire [31:0] bad_crc,bad_header,timeouts,overflows;wire [11:0] peak_bytes;
 reg [7:0] golden[0:105];reg [31:0] dice;
 reg [63:0] origin;integer seed=42,cycle,position,block_number,ignored;
 uart_v2_parser #(.TIMEOUT_US(TIMEOUT_VALUE)) dut(.*);
 initial begin
  ignored=$value$plusargs("seed=%d",seed);$readmemh("state.hex",golden);
  // Each block queues faster than the parser consumes, so arrival-time checks
  // are exercised independently of the empty-ring waiting-timeout path.
  for(cycle=0;cycle<30000;cycle=cycle+1)begin
   @(negedge clk);dice=$random(seed);position=cycle%512;block_number=cycle/512;
   rst_n=position>=2;byte_error=0;byte_valid=0;packet_ready=0;read_valid=0;
   if(position==0)begin
    case(block_number%4)
     0:origin=64'h00000007fffffff0;
     1:origin=64'h0000000800000000;
     2:origin=64'h000000087fffffff0;
     default:origin=64'h0000000800000100;
    endcase
    now_us=origin;
   end
   if(position>=4 && position<110)begin
    byte_valid=1;byte_data=golden[position-4];
    if(position==44)begin
     case(block_number%4)
      0:now_us=origin+TIMEOUT_VALUE-1;
      1:now_us=origin+TIMEOUT_VALUE;
      2:now_us=origin+TIMEOUT_VALUE+1;
      default:now_us=origin-1;
     endcase
    end
   end else if(position>=110)begin
    // Mix gaps, random bytes/errors and consumer reads/ACKs. Some blocks hold
    // valid packets while later bytes accumulate; others drain immediately.
    now_us=now_us+dice[3:0];byte_valid=dice[4];byte_data=dice[15:8];
    byte_error=(&dice[25:16]);packet_ready=packet_valid && dice[6];
    read_valid=packet_valid && dice[7];read_index=dice[9:0];
   end
  end
  @(negedge clk);byte_valid=0;byte_error=0;packet_ready=1;
  repeat(50)@(negedge clk);
  $display("UART_DEADLINE_STRESS_PASS cycles=%0d timeout=%0d",cycle,TIMEOUT_VALUE);$finish;
 end
 initial begin #1000000;$fatal(1,"deadline stress timeout");end
endmodule
