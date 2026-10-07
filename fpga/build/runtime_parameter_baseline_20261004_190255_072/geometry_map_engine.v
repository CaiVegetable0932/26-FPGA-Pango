// Purpose: backpressured pixel -> source-neighborhood mapper using an FPGA-
// generated lens LUT. This multi-cycle correctness baseline exposes its actual
// processing cycles; it must NOT be advertised as a one-pixel/clock pipeline.
// words: a00,a01,a02,a10,a11,a12,k1,k2,k3/kp1,k4/kp2,fx,fy,cx,cy.
module geometry_map_engine #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,rst_n,input wire [1:0] model,input wire [447:0] words,
 input wire request_valid,output wire request_ready,input wire [11:0] ox,oy,
 output reg result_valid,input wire result_ready,output reg source_valid,
 output reg [11:0] x0,x1,y0,y1,frac_x,frac_y,
 output reg [10:0] lut_index,input wire signed [31:0] scale0,scale1
);
 wire signed [31:0] a00=words[31:0],a01=words[63:32],a02=words[95:64];
 wire signed [31:0] a10=words[127:96],a11=words[159:128],a12=words[191:160];
 wire signed [31:0] p1=words[287:256],p2=words[319:288];
 wire signed [31:0] fx=words[351:320],fy=words[383:352],cx=words[415:384],cy=words[447:416];
 reg [3:0] state;reg [11:0] px,py;
 // Purpose: affine products of S32 and 12-bit pixels fit S48 including sums.
 // Only domain-bounded S32 values may enter the full-width square products.
 reg signed [47:0] tx0,tx1,ty0,ty1,xq,yq,uq,vq;
 reg signed [63:0] xx,yy,xy,radial_x,radial_y;
 reg signed [33:0] rsq;
 // |normalized|<=4, positive scale<32, |p|<=1 imply distorted |ray|<224;
 // S36 Q26 has margin up to 512. This avoids cascading 32x64 DSP products.
 reg signed [35:0] scaled_x,scaled_y;
 reg signed [67:0] brown_x0,brown_x1,brown_y0,brown_y1;
 reg signed [79:0] uprod,vprod;
 // Purpose: shift by 25 BEFORE narrowing to preserve Brown's low guard bit.
 wire signed [34:0] twice_xx_q=xx>>>25,twice_yy_q=yy>>>25;
 wire signed [33:0] xy_q=xy>>>26;
 wire signed [35:0] basis_x=$signed(rsq)+twice_xx_q;
 wire signed [35:0] basis_y=$signed(rsq)+twice_yy_q;
 reg signed [31:0] scale;
 reg [20:0] fraction;reg domain_ok;
 wire signed [63:0] lerp=$signed(scale1-scale0)*$signed({1'b0,fraction});
 assign request_ready=state==0 && !result_valid;
 // Purpose: all state remains stable during a cache stall; no coordinate,
 // fraction or valid-mask can migrate to a different output pixel.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   state<=0;result_valid<=0;source_valid<=0;x0<=0;x1<=0;y0<=0;y1<=0;
   frac_x<=0;frac_y<=0;lut_index<=0;px<=0;py<=0;fraction<=0;domain_ok<=0;
   tx0<=0;tx1<=0;ty0<=0;ty1<=0;xq<=0;yq<=0;xx<=0;yy<=0;xy<=0;rsq<=0;
   scale<=0;scaled_x<=0;scaled_y<=0;radial_x<=0;radial_y<=0;
   brown_x0<=0;brown_x1<=0;brown_y0<=0;brown_y1<=0;
   uprod<=0;vprod<=0;uq<=0;vq<=0;
  end else begin
   if(result_valid && result_ready)result_valid<=0;
   case(state)
    0:if(request_valid && request_ready)begin
     px<=ox;py<=oy;
     tx0<=a00*$signed({1'b0,ox});tx1<=a01*$signed({1'b0,oy});
     ty0<=a10*$signed({1'b0,ox});ty1<=a11*$signed({1'b0,oy});state<=1;
    end
    1:begin xq<=tx0+tx1+a02;yq<=ty0+ty1+a12;state<=2;end
    2:begin
     domain_ok<=xq>=-64'sd268435456 && xq<=64'sd268435456 &&
                yq>=-64'sd268435456 && yq<=64'sd268435456;
     // A previously rejected coordinate cannot overflow the square products.
     xx<=domain_bounded(xq)*domain_bounded(xq);
     yy<=domain_bounded(yq)*domain_bounded(yq);
     xy<=domain_bounded(xq)*domain_bounded(yq);state<=3;
    end
    3:begin rsq<=(xx>>>26)+(yy>>>26);state<=4;end
    4:begin
     domain_ok<=domain_ok && rsq>=0 && rsq<64'sd2147483648;
     lut_index<=rsq>=0 && rsq<64'sd2147483648 ? rsq[31:21] : 11'd0;
     fraction<=rsq[20:0];state<=5;
    end
    5:state<=6; // synchronous adjacent-entry RAM read
    6:begin scale<=scale0+(lerp>>>21);state<=7;end
    7:begin
     radial_x<=domain_bounded(xq)*scale;radial_y<=domain_bounded(yq)*scale;
     // Purpose: register complete Brown products BEFORE shifts/addition.
     // Explicit wide products prevent assignment-context truncation when
     // narrowing ray registers. Fisheye does not use these tangential terms.
     brown_x0<=p1*xy_q;brown_x1<=p2*basis_x;
     brown_y0<=p1*basis_y;brown_y1<=p2*xy_q;
     state<=8;
    end
    8:begin
     scaled_x<=(radial_x>>>26)+(model==1?((brown_x0>>>25)+(brown_x1>>>26)):68'sd0);
     scaled_y<=(radial_y>>>26)+(model==1?((brown_y0>>>26)+(brown_y1>>>25)):68'sd0);
     state<=9;
    end
    9:begin uprod<=fx*scaled_x;vprod<=fy*scaled_y;state<=10;end
    10:begin uq<=(uprod>>>30)+(cx>>>4);vq<=(vprod>>>30)+(cy>>>4);state<=11;end
    11:begin
     result_valid<=1;state<=0;frac_x<=0;frac_y<=0;
     x0<=0;x1<=0;y0<=0;y1<=0;source_valid<=0;
     if(model==0)begin
      source_valid<=1;x0<=px;x1<=px==WIDTH-1?px:px+1'b1;
      y0<=py;y1<=py==HEIGHT-1?py:py+1'b1;
     end else if(domain_ok && uq>=0 && vq>=0 &&
        uq<=(WIDTH-1)*64'sd4096 && vq<=(HEIGHT-1)*64'sd4096)begin
      source_valid<=1;x0<=uq[23:12];y0<=vq[23:12];
      x1<=uq[23:12]==WIDTH-1?uq[23:12]:uq[23:12]+1'b1;
      y1<=vq[23:12]==HEIGHT-1?vq[23:12]:vq[23:12]+1'b1;
      frac_x<=uq[11:0];frac_y<=vq[11:0];
     end
    end
   endcase
  end
 // Purpose: discard out-of-domain intermediate values before multiplication;
 // domain_ok still marks them invalid and prevents all source DDR requests.
 function signed [31:0] domain_bounded;
  input signed [63:0] value;
  begin domain_bounded=value>=-64'sd268435456 && value<=64'sd268435456 ? value[31:0] : 32'sd0;end
 endfunction
endmodule
