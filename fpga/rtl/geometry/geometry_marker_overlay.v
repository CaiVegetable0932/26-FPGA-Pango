// Purpose: final HDMI-only overlay. Source/result DDR and network bytes are
// never inputs to a write path here. All RGB and raster strobes delay TWO clocks.
// Markers are colored octagons with black outlines and compact numbered labels.
module geometry_marker_overlay #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,rst_n,input wire [1279:0] coordinates,input wire [19:0] visible_mask,
 input wire enabled,input wire [5:0] size,input wire [23:0] in_rgb,input wire in_hs,in_vs,in_de,
 output reg [23:0] rgb,output reg hs,vs,de);
 reg previous_de;reg [11:0] column,row;
 wire [11:0] px=previous_de?column:12'd0;
 reg [19:0] hit,color_hit;reg [23:0] rgb_delay;reg hs_delay,vs_delay,de_delay;
 wire [19:0] match_pixel,paint_pixel;wire [23:0] colors[0:19];
 // Purpose: immutable 3x5 digits; labels are independent of source samples.
 function [14:0] glyph;
  input integer digit;
  begin case(digit)
   0:glyph=15'b111101101101111;1:glyph=15'b010110010010111;
   2:glyph=15'b111001111100111;3:glyph=15'b111001111001111;
   4:glyph=15'b101101111001001;5:glyph=15'b111100111001111;
   6:glyph=15'b111100111101111;7:glyph=15'b111001001001001;
   8:glyph=15'b111101111101111;default:glyph=15'b111101111001111;
  endcase end
 endfunction
 // Purpose: bounded row/column selection for a 3x5 glyph. No multiply,
 // subtraction or 32-bit dynamic bitmap index exists on the pixel path.
 function glyph_dot;
  input [14:0] bitmap;input [2:0] glyph_y;input [1:0] glyph_x;
  reg [2:0] row_bits;
  begin
   case(glyph_y)
    3'd0:row_bits=bitmap[14:12];3'd1:row_bits=bitmap[11:9];
    3'd2:row_bits=bitmap[8:6];3'd3:row_bits=bitmap[5:3];
    3'd4:row_bits=bitmap[2:0];default:row_bits=3'b0;
   endcase
   case(glyph_x)
    2'd0:glyph_dot=row_bits[2];2'd1:glyph_dot=row_bits[1];
    2'd2:glyph_dot=row_bits[0];default:glyph_dot=1'b0;
   endcase
  end
 endfunction
 // Shared radius <=31, limit <=46. Full-width distance guards precede narrow sums.
 wire [4:0] radius=size[5:1];
 wire [6:0] chamfer_limit={2'b0,radius}+{3'b0,radius[4:1]};
 wire [4:0] inner_radius=radius-5'd1;
 wire [6:0] inner_sumlimit=chamfer_limit-7'd2;
 genvar g;
 generate for(g=0;g<20;g=g+1)begin:markers
  wire [15:0] unused_x,unused_y;
  localparam [4:0] MARKER_INDEX=g;
  geometry_marker_catalog #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_color(MARKER_INDEX,unused_x,unused_y,colors[g]);
  wire signed [31:0] xq=coordinates[g*64+:32],yq=coordinates[g*64+32+:32];
  // Exact Q12 rounding modulo 2^16. Overflow affects only discarded high bits.
  wire signed [15:0] mx=xq[27:12]+{15'b0,xq[11]},my=yq[27:12]+{15'b0,yq[11]};
  wire signed [15:0] dx=$signed({1'b0,px})-mx,dy=$signed({1'b0,row})-my;
  wire [15:0] ax=dx[15]?-dx:dx,ay=dy[15]?-dy:dy;
  wire [6:0] distance_sum={2'b0,ax[4:0]}+{2'b0,ay[4:0]};
  wire body=ax<={11'b0,radius} && ay<={11'b0,radius} && distance_sum<=chamfer_limit;
  // Guard r>1 prevents underflow; full ax/ay bounds prevent truncation aliases.
  wire inner_pixel=radius>5'd1 && ax<{11'b0,inner_radius} &&
    ay<{11'b0,inner_radius} && distance_sum<inner_sumlimit;
  localparam DIGITS=(g+1>=10)?2:1;
  localparam [14:0] TENS=glyph((g+1)/10),ONES=glyph((g+1)%10);
  // Reuse dx/dy with the original modulo-2^16 lx/ly/tx arithmetic.
  localparam signed [15:0] LABEL_LEFT=DIGITS*4+2, LABEL_RIGHT=DIGITS*4-1;
  wire signed [15:0] tx=mx>WIDTH/2?dx+$signed({11'b0,radius})+LABEL_LEFT:
    dx-$signed({11'b0,radius})-16'sd3;
  wire signed [15:0] ty=dy+(my<16'sd10 ? -16'sd7 : 16'sd8);
  wire label_box=tx>=-16'sd1 && tx<=LABEL_RIGHT && ty>=-16'sd1 && ty<=16'sd5;
  // Upper-bit guards reject negative/off-label offsets before truncated
  // row/column selection. x[1:0] also equals x-4 for the second digit (4..6).
  wire glyph_row_valid=ty[15:3]==13'b0 && ty[2:0]<3'd5;
  wire first_column=tx[15:2]==14'b0 && tx[1:0]<2'd3;
  wire second_column=tx[15:3]==13'b0 && tx[2] && tx[1:0]<2'd3;
  wire digit_on=glyph_row_valid &&
   ((DIGITS==1 && first_column && glyph_dot(ONES,ty[2:0],tx[1:0])) ||
    (DIGITS==2 && ((first_column && glyph_dot(TENS,ty[2:0],tx[1:0])) ||
      (second_column && glyph_dot(ONES,ty[2:0],tx[1:0])))));
  assign match_pixel[g]=enabled && in_de && visible_mask[g] && (body || label_box);
  assign paint_pixel[g]=(body && inner_pixel) || (label_box && digit_on);
 end endgenerate
 integer i;reg [23:0] selected;
 // Priority is deterministic when markers overlap; lower numbered anchors win.
 always @* begin selected=rgb_delay;
  for(i=19;i>=0;i=i-1)if(hit[i])selected=color_hit[i]?colors[i]:24'h000000;
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin previous_de<=0;column<=0;row<=0;hit<=0;color_hit<=0;
  rgb_delay<=0;hs_delay<=0;vs_delay<=0;de_delay<=0;rgb<=0;hs<=0;vs<=0;de<=0;end
 else begin
  previous_de<=in_de;
  if(in_vs)begin row<=0;column<=0;end
  else if(in_de)column<=px+1'b1;
  else if(previous_de)begin column<=0;row<=row+1'b1;end
  hit<=match_pixel;color_hit<=paint_pixel;rgb_delay<=in_rgb;
  hs_delay<=in_hs;vs_delay<=in_vs;de_delay<=in_de;
  rgb<=selected;hs<=hs_delay;vs<=vs_delay;de<=de_delay;
 end
endmodule
