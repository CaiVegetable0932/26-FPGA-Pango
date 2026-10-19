// Isolated diagnostic boundary; never instantiate in production.
module regional_wrapper(input clk,rst_n,input [31:0] scan_in,
 input [0:0] scan_addr,output [31:0] scan_out);
 reg [383:0] scan_inputs /* synthesis syn_preserve=1 */;
 wire [52:0] dut_outputs;
 reg [63:0] scan_outputs /* synthesis syn_preserve=1 */;
 always @(posedge clk) scan_inputs <= {scan_inputs[351:0],scan_in};
 always @(posedge clk) scan_outputs <= {{11{1'b0}},dut_outputs};
 assign scan_out=scan_addr<2 ? scan_outputs[scan_addr*32+:32] : 32'd0;
 raw_dma_reader dut(.clk(clk),
  .rst_n(rst_n),
  .start(scan_inputs[0+:1]),
  .start_ready(dut_outputs[0+:1]),
  .base_addr(scan_inputs[1+:32]),
  .slot_begin(scan_inputs[33+:32]),
  .slot_end(scan_inputs[65+:32]),
  .cancel(scan_inputs[97+:1]),
  .done(dut_outputs[1+:1]),
  .failed(dut_outputs[2+:1]),
  .req_valid(dut_outputs[3+:1]),
  .req_ready(scan_inputs[98+:1]),
  .req_addr(dut_outputs[4+:32]),
  .req_beats(dut_outputs[36+:5]),
  .r_valid(scan_inputs[99+:1]),
  .r_ready(dut_outputs[41+:1]),
  .r_data(scan_inputs[100+:256]),
  .dma_done(scan_inputs[356+:1]),
  .dma_done_ready(dut_outputs[42+:1]),
  .dma_error(scan_inputs[357+:1]),
  .dma_cancel(dut_outputs[43+:1]),
  .byte_valid(dut_outputs[44+:1]),
  .byte_ready(scan_inputs[358+:1]),
  .byte_data(dut_outputs[45+:8]));
endmodule
