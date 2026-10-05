// Purpose: backpressured inverse lens map. Registered partial products keep
// each wide multiplication inside the 125 MHz budget; valid tokens, rather
// than assumed DSP latency, advance the coordinate state machine.
// Parameter words and numerical rounding match the original mapper.
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
 reg [4:0] state;reg [11:0] px,py;
 reg signed [47:0] tx0,tx1,ty0,ty1,xwide,ywide,uq,vq;
 reg signed [31:0] xq,yq,scale;
 reg signed [63:0] xx,yy,xy;
 reg signed [33:0] rsq;
 reg signed [35:0] radial_x,radial_y,brown_x,brown_y,brown_x0,scaled_x,scaled_y;
 reg [20:0] fraction;reg domain_ok;
 wire signed [34:0] twice_xx_q=xx>>>25,twice_yy_q=yy>>>25;
 wire signed [33:0] xy_q=xy>>>26;
 wire signed [35:0] basis_x=$signed(rsq)+twice_xx_q,basis_y=$signed(rsq)+twice_yy_q;
 // Purpose: three shared pipelined multipliers cover squares, interpolation,
 // radial/tangential terms and projection without combinational DSP cascades.
 reg signed [31:0] ma0,ma1,ma2;reg signed [35:0] mb0,mb1,mb2;
 reg launch;wire mv0,mv1,mv2;wire signed [67:0] mp0,mp1,mp2;
 geometry_mul_pipe m0(clk,rst_n,launch,ma0,mb0,mv0,mp0);
 geometry_mul_pipe m1(clk,rst_n,launch,ma1,mb1,mv1,mp1);
 geometry_mul_pipe m2(clk,rst_n,launch,ma2,mb2,mv2,mp2);
 always @* begin
  launch=0;ma0=0;ma1=0;ma2=0;mb0=0;mb1=0;mb2=0;
  case(state)
   3:begin launch=1;ma0=xq;mb0=xq;ma1=yq;mb1=yq;ma2=xq;mb2=yq;end
   8:begin launch=1;ma0=scale1-scale0;mb0=$signed({1'b0,fraction});end
   10:begin launch=1;ma0=xq;mb0=scale;ma1=yq;mb1=scale;ma2=p1;mb2=xy_q;end
   12:begin launch=1;ma0=p2;mb0=basis_x;ma1=p1;mb1=basis_y;ma2=p2;mb2=xy_q;end
   15:begin launch=1;ma0=fx;mb0=scaled_x;ma1=fy;mb1=scaled_y;end
  endcase
 end
 assign request_ready=state==0 && !result_valid;
 // Purpose: retain the result and its validity mask through downstream stalls.
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  state<=0;result_valid<=0;source_valid<=0;x0<=0;x1<=0;y0<=0;y1<=0;
  frac_x<=0;frac_y<=0;lut_index<=0;px<=0;py<=0;fraction<=0;domain_ok<=0;
  tx0<=0;tx1<=0;ty0<=0;ty1<=0;xwide<=0;ywide<=0;xq<=0;yq<=0;
  xx<=0;yy<=0;xy<=0;rsq<=0;scale<=0;scaled_x<=0;scaled_y<=0;
  radial_x<=0;radial_y<=0;brown_x<=0;brown_y<=0;brown_x0<=0;uq<=0;vq<=0;
 end else begin
  if(result_valid && result_ready)result_valid<=0;
  case(state)
   0:if(request_valid && request_ready)begin
    px<=ox;py<=oy;
    tx0<=a00*$signed({1'b0,ox});tx1<=a01*$signed({1'b0,oy});
    ty0<=a10*$signed({1'b0,ox});ty1<=a11*$signed({1'b0,oy});state<=1;
   end
   1:begin xwide<=tx0+tx1+a02;ywide<=ty0+ty1+a12;state<=2;end
   2:begin
    // Purpose: register the domain clamp before launching a square.
    domain_ok<=xwide>=-48'sd268435456 && xwide<=48'sd268435456 &&
               ywide>=-48'sd268435456 && ywide<=48'sd268435456;
    xq<=bounded(xwide);yq<=bounded(ywide);state<=3;
   end
   3:state<=4;
   4:if(mv0 && mv1 && mv2)begin xx<=mp0;yy<=mp1;xy<=mp2;state<=5;end
   5:begin rsq<=(xx>>>26)+(yy>>>26);state<=6;end
   6:begin
    domain_ok<=domain_ok && rsq>=0 && rsq<34'sd2147483648;
    lut_index<=rsq>=0 && rsq<34'sd2147483648 ? rsq[31:21]:11'd0;
    fraction<=rsq[20:0];state<=7;
   end
   7:state<=8; // synchronous adjacent LUT entry read
   8:state<=9;
   9:if(mv0)begin scale<=scale0+(mp0>>>21);state<=10;end
   10:state<=11;
   11:if(mv0 && mv1 && mv2)begin
    radial_x<=mp0>>>26;radial_y<=mp1>>>26;brown_x0<=mp2>>>25;
    brown_x<=0;brown_y<=0;state<=model==1?12:14;
   end
   12:state<=13;
   13:if(mv0 && mv1 && mv2)begin
    brown_x<=brown_x0+(mp0>>>26);brown_y<=(mp1>>>26)+(mp2>>>25);state<=14;
   end
   14:begin scaled_x<=radial_x+brown_x;scaled_y<=radial_y+brown_y;state<=15;end
   15:state<=16;
   16:if(mv0 && mv1)begin uq<=(mp0>>>30)+(cx>>>4);vq<=(mp1>>>30)+(cy>>>4);state<=17;end
   17:begin
    result_valid<=1;state<=0;frac_x<=0;frac_y<=0;
    x0<=0;x1<=0;y0<=0;y1<=0;source_valid<=0;
    if(model==0)begin
     source_valid<=1;x0<=px;x1<=px==WIDTH-1?px:px+1'b1;
     y0<=py;y1<=py==HEIGHT-1?py:py+1'b1;
    end else if(domain_ok && uq>=0 && vq>=0 &&
      uq<=(WIDTH-1)*48'sd4096 && vq<=(HEIGHT-1)*48'sd4096)begin
     source_valid<=1;x0<=uq[23:12];y0<=vq[23:12];
     x1<=uq[23:12]==WIDTH-1?uq[23:12]:uq[23:12]+1'b1;
     y1<=vq[23:12]==HEIGHT-1?vq[23:12]:vq[23:12]+1'b1;
     frac_x<=uq[11:0];frac_y<=vq[11:0];
    end
   end
  endcase
 end
 // Purpose: reject invalid rays before multiplication and DDR addressing.
 function signed [31:0] bounded;
  input signed [47:0] value;
  begin bounded=value>=-48'sd268435456 && value<=48'sd268435456 ? value[31:0]:32'sd0;end
 endfunction
endmodule
