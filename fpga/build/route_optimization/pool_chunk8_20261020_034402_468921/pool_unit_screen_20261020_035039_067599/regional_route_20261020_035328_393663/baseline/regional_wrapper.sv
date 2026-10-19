// Isolated diagnostic boundary; never instantiate in production.
module regional_wrapper(input clk,rst_n,input [31:0] scan_in,
 input [6:0] scan_addr,output [31:0] scan_out);
 reg [1087:0] scan_inputs /* synthesis syn_preserve=1 */;
 wire [2888:0] dut_outputs;
 reg [2911:0] scan_outputs /* synthesis syn_preserve=1 */;
 always @(posedge clk) scan_inputs <= {scan_inputs[1055:0],scan_in};
 always @(posedge clk) scan_outputs <= {{23{1'b0}},dut_outputs};
 assign scan_out=scan_addr<91 ? scan_outputs[scan_addr*32+:32] : 32'd0;
 frame_pool_bank dut(.clk(clk),
  .reset_n(rst_n),
  .fabric_ready(scan_inputs[0+:1]),
  .display_boundary(scan_inputs[1+:1]),
  .cmd(scan_inputs[2+:1078]),
  .rsp(dut_outputs[0+:2889]));
endmodule
