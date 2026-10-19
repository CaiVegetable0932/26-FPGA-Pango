`timescale 1ns/1ps
// Purpose: one replicated double-page Gamma table with a single synchronous read.
// Pre/post are mutually exclusive frame modes; address mux precedes the RAM,
// avoiding accidental extra read ports when a lane is shared by both modes.
module gamma_lut_bank(
 input clk,read_enable,input [8:0] read_address,output reg [7:0] q,
 input write_enable,input [8:0] write_address,input [7:0] data
);
 reg [7:0] memory[0:511] /* synthesis syn_ramstyle="block_ram" */;
 always @(posedge clk) begin
  if(read_enable) q<=memory[read_address];
  if(write_enable) memory[write_address]<=data;
 end
endmodule
