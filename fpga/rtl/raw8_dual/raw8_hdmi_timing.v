// Purpose: 1920x1080p30 raster at 74.25 MHz, positive HS/VS, total 2200x1125.
// The RGB output is FPGA-enhanced grayscale with a Bayer-aware 2x2 display
// filter. Ethernet keeps the same tone curve but transmits Bayer RAW8 bytes.
// Consumer must prefetch a full frame into its elastic read path before enable.
// Purpose: processed grayscale bypasses both tone mapping and Bayer filtering,
// which have already happened BEFORE geometry. Legacy RAW defaults unchanged.
module raw8_hdmi_timing #(parameter PROCESSED=0)(
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
 wire [7:0] display_luma;
 // Purpose: remove isolated same-Bayer-phase spikes and apply one continuous
 // tone map. Ethernet uses the same block; neither reader changes DDR S0.
 raw8_display_enhance u_enhance(.clk(clk),.reset_n(reset_n),
  .line_active(sample_ready),.line_end(1'b0),.pixel_accept(sample_ready && sample_valid),
  .sample(sample),.luma(display_luma));
 // Purpose: prefetch the previous-line pixel during the horizontal porch,
 // then suppress Bayer-phase dots before the HDMI/capture-card downscaler.
 // This does not alter sample_ready, DE, HDMI timing, or the DDR/network path.
 wire [7:0] display_gray;
 // Purpose: use an explicitly 11-bit modulo column index for the 1920 active
 // samples, avoiding port-width truncation warnings from the 12-bit raster.
 wire [10:0] display_column=h[10:0]-11'd192;
 raw8_hdmi_gray_antialias u_gray_antialias(.clk(clk),.reset_n(reset_n),
  .line_preload(h==12'd191),.pixel_accept(sample_ready && sample_valid),
  .first_row(v==11'd41),.first_col(h==12'd192),
  .column(display_column),.luma(display_luma),.gray(display_gray));
 wire [7:0] selected_gray=PROCESSED?sample:display_gray;
 assign rgb=sample_ready && sample_valid ? {selected_gray,selected_gray,selected_gray} : 24'b0;
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin h<=0;v<=0;poisoned<=0;underflows<=0;end
  else begin
   if(h==2199)begin h<=0;if(v==1124)v<=0;else v<=v+1'b1;end
   else h<=h+1'b1;
   if(frame_boundary)poisoned<=0;
   if(sample_ready && !sample_valid)begin poisoned<=1;underflows<=underflows+1'b1;end
  end
endmodule
