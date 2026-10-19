// Isolated diagnostic boundary; never instantiate in production.
module regional_wrapper(input clk,rst_n,input [31:0] scan_in,
 input [3:0] scan_addr,output [31:0] scan_out);
 reg [447:0] scan_inputs /* synthesis syn_preserve=1 */;
 wire [401:0] dut_outputs;
 reg [415:0] scan_outputs /* synthesis syn_preserve=1 */;
 always @(posedge clk) scan_inputs <= {scan_inputs[415:0],scan_in};
 always @(posedge clk) scan_outputs <= {{14{1'b0}},dut_outputs};
 assign scan_out=scan_addr<13 ? scan_outputs[scan_addr*32+:32] : 32'd0;
 snapshot_copy_dma dut(.clk(clk),
  .rst_n(rst_n),
  .start(scan_inputs[0+:1]),
  .ready(dut_outputs[0+:1]),
  .cancel(scan_inputs[1+:1]),
  .source_slot(scan_inputs[2+:2]),
  .result_slot(scan_inputs[4+:2]),
  .source_gen(scan_inputs[6+:32]),
  .result_gen(scan_inputs[38+:32]),
  .s1_gen(scan_inputs[70+:32]),
  .dst_gen(scan_inputs[102+:32]),
  .done(dut_outputs[1+:1]),
  .failed(dut_outputs[2+:1]),
  .drained(dut_outputs[3+:1]),
  .req_valid(dut_outputs[4+:1]),
  .req_ready(scan_inputs[134+:1]),
  .req_write(dut_outputs[5+:1]),
  .req_addr(dut_outputs[6+:32]),
  .req_tag(dut_outputs[38+:32]),
  .req_bank(dut_outputs[70+:3]),
  .req_owner(dut_outputs[73+:3]),
  .req_slot(dut_outputs[76+:2]),
  .req_generation(dut_outputs[78+:32]),
  .w_valid(dut_outputs[110+:1]),
  .w_ready(scan_inputs[135+:1]),
  .w_data(dut_outputs[111+:256]),
  .w_strb(dut_outputs[367+:32]),
  .r_valid(scan_inputs[136+:1]),
  .r_ready(dut_outputs[399+:1]),
  .r_data(scan_inputs[137+:256]),
  .dma_done(scan_inputs[393+:1]),
  .dma_done_ready(dut_outputs[400+:1]),
  .dma_error(scan_inputs[394+:1]),
  .dma_cancelled(scan_inputs[395+:1]),
  .done_tag(scan_inputs[396+:32]),
  .dma_cancel(dut_outputs[401+:1]));
endmodule
