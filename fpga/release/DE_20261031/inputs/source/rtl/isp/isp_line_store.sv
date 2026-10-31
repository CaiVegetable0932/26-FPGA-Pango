`timescale 1ns/1ps
// Purpose: synchronous read-before-write line storage, with no RAM reset/mux.
// A dedicated output register exposes the exact ADS block-RAM inference pattern.
// Old data is needed when replacing row y-2; never apply no_rw_check to this RAM.
module isp_line_store #(parameter DEPTH=2048)(
 input clk,enable,write,input [$clog2(DEPTH)-1:0] address,
 input [11:0] data,output reg [11:0] q
);
 reg [11:0] memory[0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
 always @(posedge clk) if(enable) begin
  q<=memory[address];
  if(write) memory[address]<=data;
 end
endmodule
