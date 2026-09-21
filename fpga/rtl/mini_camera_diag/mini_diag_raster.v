// Purpose: unmistakable machine-readable DIAGNOSTIC raster, never camera pixels.
// Magenta header, cyan footer, 16 columns x 10 rows of bits (MSB first).
// Cell origin=(128,160), pitch=(64,32). Latch one coherent packet per HDMI frame.
module mini_diag_raster(input wire clk,reset_n,vsync,de,input wire [159:0] packet,
 output reg [23:0] rgb);
 reg [11:0] x,y;
 reg prev_de,prev_vs;
 reg [159:0] frame_packet;
 wire [11:0] dx=x-12'd128,dy=y-12'd160;
 wire [7:0] bit_index=8'd159-{dy[8:5],dx[9:6]};
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin x<=0;y<=0;prev_de<=0;prev_vs<=0;frame_packet<=0;end
  else begin
   prev_de<=de;prev_vs<=vsync;
   if(vsync && !prev_vs)frame_packet<=packet;
   if(vsync)begin x<=0;y<=0;end
   else if(de)x<=x+1'b1;
   else begin x<=0;if(prev_de)y<=y+1'b1;end
  end
 always @* begin
  rgb=24'h180018;
  if(y<80)rgb=24'hff00ff;
  else if(y>=640)rgb=24'h00ffff;
  else if(x>=128 && x<1152 && y>=160 && y<480) begin
   if(dx[5:0]<4 || dy[4:0]<4)rgb=24'h404080;
   else rgb=frame_packet[bit_index] ? 24'hffffff : 24'h000000;
  end
 end
endmodule
