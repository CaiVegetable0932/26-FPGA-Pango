// Isolated diagnostic boundary; never instantiate in production.
module regional_wrapper(input clk,rst_n,input [31:0] scan_in,
 input [3:0] scan_addr,output [31:0] scan_out);
 reg [319:0] scan_inputs /* synthesis syn_preserve=1 */;
 wire [265:0] dut_outputs;
 reg [287:0] scan_outputs /* synthesis syn_preserve=1 */;
 always @(posedge clk) scan_inputs <= {scan_inputs[287:0],scan_in};
 always @(posedge clk) scan_outputs <= {{22{1'b0}},dut_outputs};
 assign scan_out=scan_addr<9 ? scan_outputs[scan_addr*32+:32] : 32'd0;
 dma_byte_unpack dut(.clk(clk),
  .rst_n(rst_n),
  .start_valid(scan_inputs[0+:1]),
  .start_ready(dut_outputs[0+:1]),
  .start_offset(scan_inputs[1+:5]),
  .row_bytes(scan_inputs[6+:32]),
  .beat_valid(scan_inputs[38+:1]),
  .beat_ready(dut_outputs[1+:1]),
  .beat_data(scan_inputs[39+:256]),
  .chunk_valid(dut_outputs[2+:1]),
  .chunk_ready(scan_inputs[295+:1]),
  .chunk_data(dut_outputs[3+:256]),
  .valid_bytes(dut_outputs[259+:6]),
  .chunk_last(dut_outputs[265+:1]));
endmodule
