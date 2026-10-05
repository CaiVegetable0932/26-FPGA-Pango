// Purpose: construct a Bayer-phase-safe grayscale source neighborhood from
// the 3x3 RAW footprint, then interpolate FOUR GRAYS, never Bayer colors.
// Uses the existing fixed brightness curve but no destination-order median.
// Enhancement is applied once before resampling; S0/UDP bytes are unchanged.
module geometry_gray_sampler #(parameter STRIDE=2048)(
 input wire clk,rst_n,start,source_valid,enhance,input wire [27:0] base,
 input wire [11:0] x0,x1,y0,y1,frac_x,frac_y,
 output wire ready,output reg valid,input wire pixel_ready,
 output wire [7:0] pixel,output reg mask_valid,
 output wire cache_req,input wire cache_ready,output wire [27:0] cache_addr,
 input wire cache_valid,output wire cache_response_ready,input wire [7:0] cache_value
);
 reg [2:0] state;reg [3:0] item;
 reg [11:0] xx0,xx1,yy0,yy1,fx,fy;reg [27:0] held_base;
 reg held_enhance;reg [7:0] samples[0:8];reg [7:0] answer;
 reg [19:0] top,bottom;reg [31:0] weighted;
 reg [11:0] sx,sy;
 assign ready=state==0 && !valid;
 assign cache_req=state==1;
 assign cache_response_ready=state==2;
 assign cache_addr=held_base+sy*STRIDE+sx;
 assign pixel=answer;
 // Purpose: clamp causal left/up box edges and repeat the last interpolation
 // neighbor. In-bounds mappings never lose the sensor's final row/column.
 always @*begin
  case(item%3)0:sx=xx0==0?12'd0:xx0-1'b1;1:sx=xx0;default:sx=xx1;endcase
  case(item/3)0:sy=yy0==0?12'd0:yy0-1'b1;1:sy=yy0;default:sy=yy1;endcase
 end
 // Purpose: reuse the exact continuous tone curve. History is held empty here
 // because random-access samples cannot use a raster-stream median history.
 wire [7:0] enhanced;
 raw8_display_enhance u_curve(.clk(clk),.reset_n(rst_n),.line_active(1'b0),
  .line_end(1'b0),.pixel_accept(1'b0),.sample(cache_value),.luma(enhanced));
 function [7:0] average;
  input [7:0] a,b,c,d;
  reg [9:0] s;
  begin s={2'b0,a}+b+c+d+10'd2;average=s[9:2];end
 endfunction
 wire [7:0] p00=average(samples[0],samples[1],samples[3],samples[4]);
 wire [7:0] p10=average(samples[1],samples[2],samples[4],samples[5]);
 wire [7:0] p01=average(samples[3],samples[4],samples[6],samples[7]);
 wire [7:0] p11=average(samples[4],samples[5],samples[7],samples[8]);
 // Purpose: hold one pixel until the result packer accepts it. Invalid source
 // mappings skip ALL memory reads and produce an explicit black-mask pixel.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   state<=0;item<=0;valid<=0;mask_valid<=0;answer<=0;
   xx0<=0;xx1<=0;yy0<=0;yy1<=0;fx<=0;fy<=0;held_base<=0;held_enhance<=0;
   top<=0;bottom<=0;weighted<=0;
  end else begin
   if(valid && pixel_ready)valid<=0;
   case(state)
    0:if(start && ready)begin
     mask_valid<=source_valid;xx0<=x0;xx1<=x1;yy0<=y0;yy1<=y1;
     fx<=frac_x;fy<=frac_y;held_base<=base;held_enhance<=enhance;item<=0;
     if(source_valid)state<=1;else begin answer<=0;valid<=1;end
    end
    1:if(cache_ready)state<=2;
    2:if(cache_valid)begin
     samples[item]<=held_enhance?enhanced:cache_value;
     if(item==8)state<=3;else begin item<=item+1'b1;state<=1;end
    end
    3:begin
     top<=(13'd4096-{1'b0,fx})*p00+{1'b0,fx}*p10;
     bottom<=(13'd4096-{1'b0,fx})*p01+{1'b0,fx}*p11;state<=4;
    end
    4:begin weighted<=(13'd4096-{1'b0,fy})*top+{1'b0,fy}*bottom+32'd8388608;state<=5;end
    5:begin answer<=weighted[31:24];valid<=1;state<=0;end
   endcase
  end
endmodule
