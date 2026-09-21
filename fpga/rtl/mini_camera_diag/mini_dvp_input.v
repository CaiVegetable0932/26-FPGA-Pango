// Purpose: capture the complete DVP bundle once on its source PCLK so geometry
// observation and RGB565 capture consume identical samples, with one cycle latency.
// This is not an asynchronous synchronizer or a substitute for external I/O timing.
module mini_dvp_input(input wire clk,reset_n,input wire vsync,href,
 input wire [7:0] data,output reg sampled_vsync,sampled_href,
 output reg [7:0] sampled_data);
 always @(posedge clk or negedge reset_n)
  if(!reset_n) begin sampled_vsync<=1;sampled_href<=0;sampled_data<=0;end
  else begin sampled_vsync<=vsync;sampled_href<=href;sampled_data<=data;end
endmodule
