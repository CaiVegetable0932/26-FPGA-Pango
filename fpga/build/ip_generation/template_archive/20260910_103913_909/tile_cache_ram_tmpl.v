// Created by IP Generator (Version 2022.2-SP6.4 build 146967)
// Instantiation Template
//
// Insert the following codes into your Verilog file.
//   * Change the_instance_name to your own instance name.
//   * Change the signal names in the port associations


tile_cache_ram the_instance_name (
  .wr_clk(wr_clk),      // input
  .wr_en(wr_en),        // input
  .rd_clk(rd_clk),      // input
  .rd_rst(rd_rst),      // input
  .wr_addr(wr_addr),    // input [14:0]
  .wr_data(wr_data),    // input [31:0]
  .rd_addr(rd_addr),    // input [14:0]
  .rd_data(rd_data)     // output [31:0]
);
