// Created by IP Generator (Version 2022.2-SP6.4 build 146967)
// Instantiation Template
//
// Insert the following codes into your Verilog file.
//   * Change the_instance_name to your own instance name.
//   * Change the signal names in the port associations


statistics_mac the_instance_name (
  .clk(clk),              // input
  .rst(rst),              // input
  .ce(ce),                // input
  .a(a),                  // input [15:0]
  .b(b),                  // input [15:0]
  .acc_init(acc_init),    // input [47:0]
  .reload(reload),        // input
  .p(p)                   // output [47:0]
);
