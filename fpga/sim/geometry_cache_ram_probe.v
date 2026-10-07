// Purpose: isolated native ADS inference check, never a board source.
// Port A uses one physical address for read/write; B is read-only.
module geometry_cache_ram_probe(input wire clk,write,read_enable,
 input wire [9:0] fill_address,left_address,right_address,
 input wire [255:0] fill_data,output reg [255:0] left_data,right_data);
 wire [9:0] address_a=write?fill_address:left_address;
 reg [255:0] data[0:1023] /* synthesis syn_ramstyle="block_ram" */;
 // Purpose: match the candidate cache's clock-enabled port, including an
 // unused read-during-write value on refill cycles.
 always @(posedge clk)if(write || read_enable)begin
  if(write)data[address_a]<=fill_data;
  left_data<=data[address_a];
 end
 always @(posedge clk)if(read_enable)right_data<=data[right_address];
endmodule
