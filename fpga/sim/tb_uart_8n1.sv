`timescale 1ns/1ps
// Actual 125MHz / 460800 divider, center sampling at nominal and +/-2% byte
// timing; false start, bad stop and all 256 TX bytes through a second receiver.
module tb_uart_8n1;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,rx=1,tx_valid=0;reg [7:0] tx_data=0;
 wire tx,tx_ready,rx_valid,framing_error;wire [7:0] rx_data;
 wire loop_valid,loop_error;wire [7:0] loop_data;
 integer expected_rx=0,rx_count=0,errors=0,loop_count=0,i,j;
 uart_8n1 dut(.*);
 uart_8n1 loop_rx(.clk(clk),.rst_n(rst_n),.rx(tx),.tx(),.rx_valid(loop_valid),.rx_data(loop_data),
  .framing_error(loop_error),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk) begin
  if(rx_valid) begin if(rx_data!=expected_rx) $fatal(1,"RX byte");rx_count=rx_count+1;end
  if(framing_error) errors=errors+1;
  if(loop_error) $fatal(1,"TX stop bit");
  if(loop_valid) begin if(loop_data!=loop_count) $fatal(1,"TX loop byte %0d != %0d",loop_data,loop_count);loop_count=loop_count+1;end
 end
 task serial_byte(input [7:0] b,input integer bit_cycles,input bit stop_bit);
  begin
   @(negedge clk);rx=0;repeat(bit_cycles) @(negedge clk);
   for(j=0;j<8;j=j+1) begin rx=b[j];repeat(bit_cycles) @(negedge clk);end
   rx=stop_bit;repeat(bit_cycles) @(negedge clk);rx=1;repeat(400) @(negedge clk);
  end
 endtask
 initial begin
  repeat(5) @(negedge clk);rst_n=1;
  rx=0;repeat(20) @(negedge clk);rx=1;repeat(300) @(negedge clk);
  expected_rx=8'h55;serial_byte(8'h55,271,1);
  expected_rx=8'ha5;serial_byte(8'ha5,266,1);
  expected_rx=8'hf0;serial_byte(8'hf0,276,1);
  serial_byte(8'h00,271,0);if(rx_count!=3 || errors!=1) $fatal(1,"serial errors");
  for(i=0;i<256;i=i+1) begin
   wait(tx_ready);@(negedge clk);tx_data=i;tx_valid=1;@(negedge clk);tx_valid=0;
  end
  wait(loop_count==256);
  $display("UART_8N1_PASS rx=%0d framing=%0d tx=%0d",rx_count,errors,loop_count);$finish;
 end
 initial begin #10000000;$fatal(1,"UART timeout");end
endmodule
