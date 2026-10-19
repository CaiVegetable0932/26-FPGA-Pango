`timescale 1ns/1ps
// Independent full-duplex UART, integer divider with center sampling and 2FF
// asynchronous RX input synchronizer. CLK_HZ/BAUD rounding error is static;
// board oscillator/HSI error and IO voltage remain separate hardware checks.
module uart_8n1 #(parameter CLK_HZ=125000000,BAUD=460800)(
 input clk,input rst_n,input rx,output reg tx,
 output reg rx_valid,output reg [7:0] rx_data,output reg framing_error,
 input tx_valid,output tx_ready,input [7:0] tx_data
);
 localparam DIV=(CLK_HZ+BAUD/2)/BAUD;
 reg rx_meta,rx_sync;
 reg [3:0] rx_state,tx_bits;
 reg [31:0] rx_count,tx_count;
 reg [7:0] rx_shift;reg [9:0] tx_shift;
 assign tx_ready=tx_bits==0;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin rx_meta<=1;rx_sync<=1;end
  else begin rx_meta<=rx;rx_sync<=rx_meta;end
 end
 // False starts and invalid stop bits are counted by the receiving service;
 // byte_valid is emitted once only after a valid stop-bit sample.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin rx_state<=0;rx_count<=0;rx_shift<=0;rx_valid<=0;rx_data<=0;framing_error<=0;end
  else begin
   rx_valid<=0;framing_error<=0;
   if(rx_state==0) begin if(!rx_sync) begin rx_state<=1;rx_count<=DIV/2-1;end end
   else if(rx_count!=0) rx_count<=rx_count-1;
   else begin
    rx_count<=DIV-1;
    if(rx_state==1) begin if(rx_sync) rx_state<=0;else rx_state<=2;end
    else if(rx_state<10) begin rx_shift[rx_state-2]<=rx_sync;rx_state<=rx_state+1'b1;end
    else begin
     rx_state<=0;
     if(rx_sync) begin rx_data<=rx_shift;rx_valid<=1;end else framing_error<=1;
    end
   end
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin tx<=1;tx_bits<=0;tx_count<=0;tx_shift<=10'h3ff;end
  else if(tx_valid && tx_ready) begin
   tx_shift<={1'b1,tx_data,1'b0};tx<=0;tx_bits<=10;tx_count<=DIV-1;
  end else if(tx_bits!=0) begin
   if(tx_count!=0) tx_count<=tx_count-1;
   else begin
    tx_count<=DIV-1;tx_bits<=tx_bits-1'b1;tx_shift<={1'b1,tx_shift[9:1]};tx<=tx_shift[1];
   end
  end
 end
endmodule
