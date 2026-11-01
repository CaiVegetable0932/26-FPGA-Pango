`timescale 1ns/1ps
// Purpose: one synchronous RGB888 cache bank, independent read/write addresses.
// Cache control grants reads or refills exclusively, so no same-address collision
// is possible. Keep RAM accesses outside reset and lane mux logic for ADS inference.
// Fixed-gray callers retain only one byte; generic RGB callers keep 24 bits.
module rgb_cache_bank #(parameter WORDS=8192,PIXEL_BITS=24)(
 input clk,read_enable,input [$clog2(WORDS)-1:0] read_address,output reg [PIXEL_BITS-1:0] q,
 input write_enable,input [$clog2(WORDS)-1:0] write_address,input [PIXEL_BITS-1:0] data
);
 reg [PIXEL_BITS-1:0] memory[0:WORDS-1] /* synthesis syn_ramstyle="block_ram" */;
 always @(posedge clk) begin
  if(read_enable) q<=memory[read_address];
  if(write_enable) memory[write_address]<=data;
 end
endmodule
