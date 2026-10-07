// Purpose: FPGA forward source-to-output mapping, by reversing the SAME
// interpolated radial LUT used by geometry_map_engine. No uploaded coordinates.
// Radial Brown (p1=p2=0), fisheye and bypass are supported. Tangential Brown,
// singular affine transforms and out-of-domain rays fail explicitly, never clamp.
module geometry_marker_map #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,rst_n,start,original,input wire [1:0] model,
 input wire [447:0] words,input wire [15:0] sx,sy,
 output reg done,visible,failed,output reg signed [31:0] dx,dy,
 output reg [10:0] lut_index,input wire signed [31:0] scale0,scale1);
 wire signed [31:0] a=words[31:0],b=words[63:32],c=words[95:64];
 wire signed [31:0] d=words[127:96],e=words[159:128],f=words[191:160];
 wire signed [31:0] fx=words[351:320],fy=words[383:352],cx=words[415:384],cy=words[447:416];
 reg [5:0] state;reg [5:0] iteration;reg signed [31:0] nx,ny,radius,lo,hi,mid,scale,qx,qy;
 reg signed [63:0] square_x,det,part,ux,uy;
 reg [63:0] radicand;reg [33:0] root_rem;reg [31:0] root;
 wire [33:0] root_trial=({2'b0,root}<<2)|34'd1;
 wire [33:0] root_next=(root_rem<<2)|{32'b0,radicand[63:62]};
 reg [20:0] fraction;
 reg mul_start;reg signed [35:0] ma,mb;wire mul_done;wire signed [71:0] product;
 geometry_mul_pipe #(.A_WIDTH(36),.B_WIDTH(36)) u_mul(clk,rst_n,mul_start,ma,mb,mul_done,product);
 reg div_start;reg signed [95:0] numerator;reg signed [63:0] denominator;
 wire div_done,div_failed;wire signed [95:0] quotient;
 geometry_marker_divide u_div(clk,rst_n,div_start,numerator,denominator,div_done,div_failed,quotient);
 // Purpose: one multiplier is reused across normalization, LUT inversion and
 // inverse affine projection; each result is consumed only on its valid token.
 always @* begin
  mul_start=0;ma=0;mb=0;div_start=0;numerator=0;denominator=1;
  case(state)
   1:begin div_start=1;numerator=($signed({1'b0,sx,16'b0})-$signed(cx));numerator=numerator<<<26;denominator=fx;end
   3:begin div_start=1;numerator=($signed({1'b0,sy,16'b0})-$signed(cy));numerator=numerator<<<26;denominator=fy;end
   5:begin mul_start=1;ma=nx;mb=nx;end
   7:begin mul_start=1;ma=ny;mb=ny;end
   11:begin mul_start=1;ma=mid;mb=mid;end
   14:begin mul_start=1;ma=scale1-scale0;mb=$signed({1'b0,fraction});end
   16:begin mul_start=1;ma=mid;mb=scale;end
   19:begin mul_start=1;ma=nx;mb=mid;end
   21:begin div_start=1;numerator=part;denominator=radius;end
   23:begin mul_start=1;ma=ny;mb=mid;end
   25:begin div_start=1;numerator=part;denominator=radius;end
   27:begin mul_start=1;ma=a;mb=e;end
   29:begin mul_start=1;ma=b;mb=d;end
   31:begin mul_start=1;ma=$signed(qx)-$signed({{4{c[31]}},c});mb=e;end
   33:begin mul_start=1;ma=$signed(qy)-$signed({{4{f[31]}},f});mb=b;end
   35:begin mul_start=1;ma=$signed(qy)-$signed({{4{f[31]}},f});mb=a;end
   37:begin mul_start=1;ma=$signed(qx)-$signed({{4{c[31]}},c});mb=d;end
   39:begin div_start=1;numerator=ux;numerator=numerator<<<12;denominator=det;end
   41:begin div_start=1;numerator=uy;numerator=numerator<<<12;denominator=det;end
  endcase
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  state<=0;done<=0;visible<=0;failed<=0;dx<=32'sh80000000;dy<=32'sh80000000;
  nx<=0;ny<=0;radius<=0;lo<=0;hi<=0;mid<=0;scale<=0;qx<=0;qy<=0;
  square_x<=0;part<=0;det<=0;ux<=0;uy<=0;radicand<=0;root_rem<=0;root<=0;
  iteration<=0;fraction<=0;lut_index<=0;
 end else begin
  done<=0;
  case(state)
   0:if(start)begin
    visible<=0;failed<=0;dx<=32'sh80000000;dy<=32'sh80000000;
    if(original || model==0)begin dx<={sx,12'b0};dy<={sy,12'b0};visible<=1;done<=1;end
    else if(model>2 || fx<=0 || fy<=0 || (model==1 && words[319:256]!=0))begin failed<=1;done<=1;end
    else state<=1;
   end
   1:state<=2;
   2:if(div_done)begin
    if(div_failed || quotient < -96'sd268435456 || quotient>96'sd268435456)state<=45;
    else begin nx<=quotient;state<=3;end
   end
   3:state<=4;
   4:if(div_done)begin
    if(div_failed || quotient < -96'sd268435456 || quotient>96'sd268435456)state<=45;
    else begin ny<=quotient;state<=5;end
   end
   5:state<=6;
   6:if(mul_done)begin square_x<=product;state<=7;end
   7:state<=8;
   8:if(mul_done)begin radicand<=square_x+product;root<=0;root_rem<=0;iteration<=0;state<=9;end
   9:begin
    radicand<=radicand<<2;
    if(root_next>=root_trial)begin root_rem<=root_next-root_trial;root<=(root<<1)|1;end
    else begin root_rem<=root_next;root<=root<<1;end
    if(iteration==31)state<=10;else iteration<=iteration+1'b1;
   end
   10:begin
    radius<=root;lo<=0;hi<=379625062;mid<=189812531;iteration<=0;
    if(root==0)begin qx<=0;qy<=0;state<=27;end else state<=11;
   end
   11:state<=12;
   12:if(mul_done)begin lut_index<=product[57:47];fraction<=product[46:26];state<=13;end
   13:state<=14;
   14:state<=15;
   15:if(mul_done)begin scale<=scale0+(product>>>21);state<=16;end
   16:state<=17;
   17:if(mul_done)begin
    if((product>>>26)<radius)lo<=mid;else hi<=mid;
    if(iteration==29)state<=18;else begin iteration<=iteration+1'b1;state<=44;end
   end
   44:begin mid<=lo+((hi-lo)>>>1);state<=11;end
   18:begin
    // A root at the LUT boundary means this source ray was not representable.
    if(hi>=379625060)state<=45;else begin mid<=lo+((hi-lo)>>>1);state<=19;end
   end
   19:state<=20;
   20:if(mul_done)begin part<=product;state<=21;end
   21:state<=22;
   22:if(div_done)begin qx<=quotient;state<=23;end
   23:state<=24;
   24:if(mul_done)begin part<=product;state<=25;end
   25:state<=26;
   26:if(div_done)begin qy<=quotient;state<=27;end
   27:begin
    if(qx < -268435456 || qx>268435456 || qy < -268435456 || qy>268435456)state<=45;
    else state<=28;
   end
   28:if(mul_done)begin part<=product;state<=29;end
   29:state<=30;
   30:if(mul_done)begin det<=part-product;state<=31;end
   31:if(det==0)state<=45;else state<=32;
   32:if(mul_done)begin part<=product;state<=33;end
   33:state<=34;
   34:if(mul_done)begin ux<=part-product;state<=35;end
   35:state<=36;
   36:if(mul_done)begin part<=product;state<=37;end
   37:state<=38;
   38:if(mul_done)begin uy<=part-product;state<=39;end
   39:state<=40;
   40:if(div_done)begin
    if(div_failed || quotient < -96'sd2147483647 || quotient>96'sd2147483647)state<=45;
    else begin dx<=quotient;state<=41;end
   end
   41:state<=42;
   42:if(div_done)begin
    if(div_failed || quotient < -96'sd2147483647 || quotient>96'sd2147483647)state<=45;
    else begin dy<=quotient;state<=43;end
   end
   43:begin visible<=dx>=0 && dy>=0 && dx<=(WIDTH-1)*4096 && dy<=(HEIGHT-1)*4096;done<=1;state<=0;end
   45:begin failed<=1;dx<=32'sh80000000;dy<=32'sh80000000;done<=1;state<=0;end
  endcase
 end
endmodule
