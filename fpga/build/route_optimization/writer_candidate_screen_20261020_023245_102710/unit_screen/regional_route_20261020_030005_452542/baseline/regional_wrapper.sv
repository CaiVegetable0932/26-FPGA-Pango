// Isolated diagnostic boundary; never instantiate in production.
module regional_wrapper(input clk,rst_n,input [31:0] scan_in,
 input [3:0] scan_addr,output [31:0] scan_out);
 reg [255:0] scan_inputs /* synthesis syn_preserve=1 */;
 wire [397:0] dut_outputs;
 reg [415:0] scan_outputs /* synthesis syn_preserve=1 */;
 always @(posedge clk) scan_inputs <= {scan_inputs[223:0],scan_in};
 always @(posedge clk) scan_outputs <= {{18{1'b0}},dut_outputs};
 assign scan_out=scan_addr<13 ? scan_outputs[scan_addr*32+:32] : 32'd0;
 frame_pixel_writer dut(.clk(clk),
  .rst_n(rst_n),
  .frame_valid(scan_inputs[0+:1]),
  .frame_ready(dut_outputs[0+:1]),
  .frame_base(scan_inputs[1+:32]),
  .frame_stride(scan_inputs[33+:32]),
  .frame_generation(scan_inputs[65+:32]),
  .frame_width(scan_inputs[97+:16]),
  .frame_height(scan_inputs[113+:16]),
  .frame_rgb888(scan_inputs[129+:1]),
  .frame_abort(scan_inputs[130+:1]),
  .in_valid(scan_inputs[131+:1]),
  .in_ready(dut_outputs[1+:1]),
  .in_pixel(scan_inputs[132+:24]),
  .in_x(scan_inputs[156+:16]),
  .in_y(scan_inputs[172+:16]),
  .frame_done(dut_outputs[2+:1]),
  .frame_failed(dut_outputs[3+:1]),
  .accepted_pixels(dut_outputs[4+:32]),
  .req_valid(dut_outputs[36+:1]),
  .req_ready(scan_inputs[188+:1]),
  .req_write(dut_outputs[37+:1]),
  .req_addr(dut_outputs[38+:32]),
  .req_tag(dut_outputs[70+:32]),
  .req_beats(dut_outputs[102+:5]),
  .w_valid(dut_outputs[107+:1]),
  .w_ready(scan_inputs[189+:1]),
  .w_data(dut_outputs[108+:256]),
  .w_strb(dut_outputs[364+:32]),
  .dma_cancel(dut_outputs[396+:1]),
  .done(scan_inputs[190+:1]),
  .done_ready(dut_outputs[397+:1]),
  .dma_error(scan_inputs[191+:1]),
  .dma_cancelled(scan_inputs[192+:1]),
  .done_tag(scan_inputs[193+:32]));
endmodule
