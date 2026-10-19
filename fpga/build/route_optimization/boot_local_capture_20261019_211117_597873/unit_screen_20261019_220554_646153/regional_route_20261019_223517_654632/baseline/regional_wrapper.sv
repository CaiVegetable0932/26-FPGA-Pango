// Isolated diagnostic boundary; never instantiate in production.
module regional_wrapper(input clk,rst_n,input [31:0] scan_in,
 input [4:0] scan_addr,output [31:0] scan_out);
 reg [3871:0] scan_inputs /* synthesis syn_preserve=1 */;
 wire [902:0] dut_outputs;
 reg [927:0] scan_outputs /* synthesis syn_preserve=1 */;
 always @(posedge clk) scan_inputs <= {scan_inputs[3839:0],scan_in};
 always @(posedge clk) scan_outputs <= {{25{1'b0}},dut_outputs};
 assign scan_out=scan_addr<29 ? scan_outputs[scan_addr*32+:32] : 32'd0;
 pc_video_boot dut(.clk(clk),
  .rst_n(rst_n),
  .uart_rx(scan_inputs[0+:1]),
  .uart_tx(dut_outputs[0+:1]),
  .configured(dut_outputs[1+:1]),
  .epoch(dut_outputs[2+:64]),
  .local_mac(dut_outputs[66+:48]),
  .peer_mac(dut_outputs[114+:48]),
  .local_ip(dut_outputs[162+:32]),
  .peer_ip(dut_outputs[194+:32]),
  .local_port(dut_outputs[226+:16]),
  .peer_port(dut_outputs[242+:16]),
  .control_status(scan_inputs[1+:768]),
  .mode_submit_valid(dut_outputs[258+:1]),
  .mode_submit_ready(scan_inputs[769+:1]),
  .mode_submit(dut_outputs[259+:2]),
  .mode_version(dut_outputs[261+:32]),
  .geometry_status(scan_inputs[770+:768]),
  .snapshot_s1_status(scan_inputs[1538+:768]),
  .snapshot_result_status(scan_inputs[2306+:768]),
  .snapshot_geometry_status(scan_inputs[3074+:768]),
  .geometry_submit_valid(dut_outputs[293+:1]),
  .geometry_submit_ready(scan_inputs[3842+:1]),
  .geometry_submit(dut_outputs[294+:544]),
  .geometry_version(dut_outputs[838+:32]),
  .geometry_entity_id(dut_outputs[870+:32]),
  .snapshot_arm(dut_outputs[902+:1]),
  .snapshot_arm_ready(scan_inputs[3843+:1]));
endmodule
