`timescale 1ns/1ps
// Purpose: passively observe raw CAM1 geometry before configuration/warmup gates.
// OV5640 DVP guide section 4.2: active data has VSYNC low and HREF high.
// Sticky flags prove an event occurred, not continuous image integrity.
module mini_dvp_observe #(parameter WIDTH_BYTES=2560, HEIGHT=720)(
 input clk,reset_n,vsync,href, output reg [3:0] seen
);
 reg vs_d,href_d,in_frame,all_lines_good;
 reg [15:0] bytes_in_line,lines_in_frame;
 always @(posedge clk or negedge reset_n)
  if(!reset_n) begin
   vs_d<=0;href_d<=0;in_frame<=0;all_lines_good<=1;
   bytes_in_line<=0;lines_in_frame<=0;seen<=0;
  end else begin
   vs_d<=vsync;href_d<=href;
   if(vs_d!=vsync) seen[0]<=1;
   if(href_d!=href) seen[1]<=1;
   // Purpose: close each raw frame on VSYNC rising; reject partial startup.
   if(vsync && !vs_d) begin
    // Purpose: flush a final line whose HREF fall coincides with VSYNC rise.
    // No pixel on the new (VSYNC-high) boundary itself is counted as active.
    if(href_d && bytes_in_line==WIDTH_BYTES) seen[2]<=1;
    if(in_frame && all_lines_good &&
       ((!href_d && lines_in_frame==HEIGHT) ||
        (href_d && bytes_in_line==WIDTH_BYTES && lines_in_frame==HEIGHT-1))) seen[3]<=1;
    in_frame<=0;bytes_in_line<=0;
   end else if(!vsync && vs_d) begin
    // Purpose: first valid byte can coincide with VSYNC falling/HREF rising.
    in_frame<=1;lines_in_frame<=0;bytes_in_line<=href ? 16'd1 : 16'd0;all_lines_good<=1;
   end else if(!vsync && href) begin
    if(bytes_in_line!=16'hffff) bytes_in_line<=bytes_in_line+1'b1;
   end else if(!vsync && !href && href_d) begin
    if(bytes_in_line==WIDTH_BYTES) seen[2]<=1;
    if(in_frame) begin
     if(lines_in_frame!=16'hffff) lines_in_frame<=lines_in_frame+1'b1;
     if(bytes_in_line!=WIDTH_BYTES) all_lines_good<=0;
    end
    bytes_in_line<=0;
   end
  end
endmodule
