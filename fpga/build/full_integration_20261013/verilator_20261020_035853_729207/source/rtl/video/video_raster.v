`timescale 1ns/1ps
// Purpose: free-running progressive raster. Defaults are 2200x1125 at
// 74.25 MHz (1920x1080, 30 Hz), positive HS/VS. Never stalls for memory.
// Sync/back porch precede active video so frame_start gives prefetch time.
module video_raster #(
 parameter H_ACTIVE=1920,H_SYNC=44,H_BACK=148,H_FRONT=88,
 parameter V_ACTIVE=1080,V_SYNC=5,V_BACK=36,V_FRONT=4
)(input clk,input rst_n,output hs,vs,de,frame_start,line_prepare,
 output [11:0] x,y);
 localparam HT=H_SYNC+H_BACK+H_ACTIVE+H_FRONT;
 localparam VT=V_SYNC+V_BACK+V_ACTIVE+V_FRONT;
 reg [11:0] h,v;
 assign hs=h<H_SYNC;
 assign vs=v<V_SYNC;
 assign de=h>=H_SYNC+H_BACK && h<H_SYNC+H_BACK+H_ACTIVE &&
           v>=V_SYNC+V_BACK && v<V_SYNC+V_BACK+V_ACTIVE;
 assign frame_start=h==0 && v==0;
 // Four pixel clocks cover synchronous line RAM and reservoir preload.
 assign line_prepare=h==H_SYNC+H_BACK-4 &&
                     v>=V_SYNC+V_BACK && v<V_SYNC+V_BACK+V_ACTIVE;
 assign x=de ? h-(H_SYNC+H_BACK) : 12'd0;
 assign y=(v>=V_SYNC+V_BACK && v<V_SYNC+V_BACK+V_ACTIVE) ? v-(V_SYNC+V_BACK) : 12'd0;
 // Purpose: counters continue through empty/failed display frames.
 always @(posedge clk or negedge rst_n)
  if(!rst_n) begin h<=0;v<=0;end
  else if(h==HT-1) begin h<=0;v<=(v==VT-1)?12'd0:v+1'b1;end
  else h<=h+1'b1;
endmodule
