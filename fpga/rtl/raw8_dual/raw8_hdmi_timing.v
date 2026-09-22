// Purpose: 1920x1080p30 raster at 74.25 MHz, positive HS/VS, total 2200x1125.
// The RGB output is an unprocessed RAW mosaic shown as gray, NOT FPGA ISP S1.
// Consumer must prefetch a full frame into its elastic read path before enable.
module raw8_hdmi_timing(
 input wire clk,reset_n,enable,input wire [7:0] sample,
 input wire sample_valid,output wire sample_ready,
 output wire hsync,vsync,de,frame_boundary,output wire [23:0] rgb,
 output reg [31:0] underflows
);
 reg [11:0] h;reg [10:0] v;
 reg poisoned;
 assign hsync=h<44;
 assign vsync=v<5;
 assign de=h>=192 && h<2112 && v>=41 && v<1121;
 assign frame_boundary=h==0 && v==0;
 // Purpose: if an underflow occurs, blank the remainder instead of shifting
 // every later pixel. The DMA must flush and restart at the next frame boundary.
 assign sample_ready=de && enable && !poisoned;
 assign rgb=sample_ready && sample_valid ? {sample,sample,sample} : 24'b0;
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin h<=0;v<=0;poisoned<=0;underflows<=0;end
  else begin
   if(h==2199)begin h<=0;if(v==1124)v<=0;else v<=v+1'b1;end
   else h<=h+1'b1;
   if(frame_boundary)poisoned<=0;
   if(sample_ready && !sample_valid)begin poisoned<=1;underflows<=underflows+1'b1;end
  end
endmodule
