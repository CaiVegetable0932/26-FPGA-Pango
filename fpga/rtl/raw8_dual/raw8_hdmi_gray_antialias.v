// Purpose: remove the 2x2 Bayer-phase checker from HDMI grayscale without
// changing the 1080p raster, the DDR RAW8 frame, or the Ethernet RAW8 bytes.
// A causal 2x2 box uses this pixel, its left neighbor, and the matching two
// pixels of the previous line. The one-pixel left/up footprint preserves
// streaming timing; the first row/column replicate their available edge.
module raw8_hdmi_gray_antialias(
 input wire clk,reset_n,line_preload,pixel_accept,first_row,first_col,
 input wire [10:0] column,input wire [7:0] luma,
 output wire [7:0] gray
);
 // Purpose: infer a native DRM line store with one clocked read and one write.
 // Reading the next column at the preceding pixel makes the prior-row sample
 // available before the current HDMI pixel; line_preload fetches column zero
 // during the last porch clock. PDS ADS guide v2.2 section 5.16 documents
 // syn_ramstyle="block_ram" for inferred RAM mapped to DRM resources.
 reg [7:0] previous_line [0:1919] /* synthesis syn_ramstyle="block_ram" */;
 reg [7:0] prior_pixel;
 reg [7:0] current_left,prior_left;
 always @(posedge clk) begin
  if(line_preload)prior_pixel<=previous_line[0];
  else if(pixel_accept)begin
   previous_line[column]<=luma;
   if(column<11'd1919)prior_pixel<=previous_line[column+11'd1];
  end
 end
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n)begin current_left<=0;prior_left<=0;end
  else if(line_preload)begin current_left<=0;prior_left<=0;end
  else if(pixel_accept)begin
   current_left<=luma;
   prior_left<=prior_pixel;
  end
 end
 // Purpose: include each Bayer phase exactly once at every interior pixel.
 // Round to nearest gray code; no tone curve, gamma, or temporal operation is
 // applied here, so Ethernet and HDMI retain the same brightness calibration.
 wire [7:0] left_current=first_col ? luma : current_left;
 wire [7:0] top_current=first_row ? luma : prior_pixel;
 wire [7:0] top_left=first_row ? left_current :
                     first_col ? top_current : prior_left;
 wire [9:0] sum={2'b0,luma}+{2'b0,left_current}+
                {2'b0,top_current}+{2'b0,top_left}+10'd2;
 assign gray=sum[9:2];
endmodule
