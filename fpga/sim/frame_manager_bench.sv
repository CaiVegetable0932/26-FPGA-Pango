`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: isolated synthesis harness; serialized command/response retains all
// control fields without thousands of chip I/O pins. This is never a board top
// and supplies no camera, DDR payload, CDC, physical I/O or hardware evidence.
module frame_manager_bench(
 input wire clk, reset_n, fabric_ready, display_boundary,
 input wire shift_in, execute, sample, shift_out,
 input wire [2:0] bank,
 input wire [31:0] command_word,
 output wire [31:0] response_word
);
 localparam CB=$bits(frame_cmd_t), RB=$bits(frame_rsp_t);
 reg [CB-1:0] input_shift;
 reg [RB-1:0] output_shift;
 reg [3*CMD_BITS-1:0] command;
 wire [3*RSP_BITS-1:0] response;
 integer i;
 always @* begin
  for(i=0;i<3;i=i+1) begin
   command[i*CMD_BITS+:CMD_BITS]='0;
   if(execute && bank==i) command[i*CMD_BITS+:CMD_BITS]=input_shift;
  end
 end
 // Purpose: register external observation paths so timing analysis measures
 // the control core between real flops rather than unconstrained I/O paths.
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin input_shift<=0; output_shift<=0; end
  else begin
   if(shift_in) input_shift<={input_shift[CB-33:0],command_word};
   if(sample && bank<3) output_shift<=response[bank*RSP_BITS+:RSP_BITS];
   else if(shift_out) output_shift<={32'b0,output_shift[RB-1:32]};
  end
 end
 assign response_word=output_shift[31:0];
 frame_manager manager(clk,reset_n,fabric_ready,display_boundary,command,response);
endmodule
