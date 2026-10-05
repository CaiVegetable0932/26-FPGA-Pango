// Purpose: derive a double-buffered radial scale table INSIDE the FPGA from
// K/D parameters. No PC coordinate map is accepted. Fisheye follows OpenCV's
// theta=atan(r), theta_d=theta*(1+k1*t2+k2*t4+k3*t6+k4*t8).
// Each entry represents r^2=i/32 in unsigned Q26. A shared restoring square
// root, vectoring CORDIC and divider are configuration-time operations only.
module geometry_lens_lut(
 input wire clk,rst_n,start,build_bank,input wire [1:0] model,
 input wire signed [31:0] k1,k2,k3,k4,
 output reg busy,done,failed,
 input wire read_bank,input wire [10:0] read_index,
 output reg signed [31:0] scale0,scale1
);
 localparam signed [31:0] ONE=32'sd67108864;
 // Purpose: two mirrored RAMs provide adjacent synchronous reads plus a
 // configuration write; each physical RAM has only one read and one write.
 reg signed [31:0] lut0[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 reg signed [31:0] lut1[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 wire [11:0] ra0={read_bank,read_index};
 wire [11:0] ra1={read_bank,read_index}+12'd1;
 reg write_entry;reg [11:0] wa;reg signed [31:0] wd;
 always @(posedge clk)begin
  scale0<=lut0[ra0];scale1<=lut1[ra1];
  if(write_entry)begin lut0[wa]<=wd;lut1[wa]<=wd;end
 end
 reg bank;reg [1:0] kind;reg [10:0] index;
 reg signed [31:0] c1,c2,c3,c4,r,theta,z,cx,cy,base_scale;
 // Purpose: accepted |k|<=1 bounds Brown Horner intermediates to 1057 Q26
 // and fish-eye theta<=atan(sqrt(32)) bounds them below 32 Q26. Forty signed
 // bits preserve even rejected candidate values without a 64x33 multiplier.
 reg signed [32:0] u;reg signed [39:0] poly;
 reg [4:0] state;reg [6:0] step;
 reg [63:0] radicand,dividend;
 // Purpose: a restoring-root remainder uses at most 33 bits; its next trial
 // uses 34. A restoring division remainder is strictly below its 32-bit
 // divisor. Keep guard bits in trials, rather than 64-bit feedback adders.
 reg [33:0] root_rem;reg [31:0] divide_rem;
 reg [31:0] root,quotient,divisor;
 reg signed [79:0] product;
 reg [63:0] previous_radius;
 wire [33:0] sr=(root_rem<<2)|{32'b0,radicand[63:62]};
 wire [33:0] trial=({2'b0,root}<<2)|34'd1;
 wire [32:0] dr={divide_rem,dividend[63]};
 // Purpose: atan(2^-i), radians Q26, immutable mathematical constants.
 function signed [31:0] atan_step;
  input [6:0] i;
  begin case(i)
   0:atan_step=52707179;1:atan_step=31114864;2:atan_step=16440240;
   3:atan_step=8345322;4:atan_step=4188854;5:atan_step=2096470;
   6:atan_step=1048491;7:atan_step=524277;8:atan_step=262143;
   9:atan_step=131072;10:atan_step=65536;11:atan_step=32768;
   12:atan_step=16384;13:atan_step=8192;14:atan_step=4096;
   15:atan_step=2048;16:atan_step=1024;17:atan_step=512;
   18:atan_step=256;19:atan_step=128;20:atan_step=64;
   21:atan_step=32;22:atan_step=16;23:atan_step=8;
   default:atan_step=0;
  endcase end
 endfunction
 // Purpose: keep full products registered before Q26 narrowing. Reject
 // nonpositive, nonmonotonic or unrepresentable tables rather than wrapping.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   busy<=0;done<=0;failed<=0;state<=0;write_entry<=0;wa<=0;wd<=0;
   index<=0;bank<=0;kind<=0;c1<=0;c2<=0;c3<=0;c4<=0;
   step<=0;radicand<=0;root_rem<=0;root<=0;dividend<=0;
   divide_rem<=0;quotient<=0;divisor<=0;previous_radius<=0;
   u<=0;r<=0;theta<=0;z<=0;cx<=0;cy<=0;poly<=0;base_scale<=0;product<=0;
  end else begin
   done<=0;write_entry<=0;
   case(state)
    0:if(start)begin
     busy<=1;failed<=0;bank<=build_bank;kind<=model;
     c1<=k1;c2<=k2;c3<=k3;c4<=k4;index<=0;previous_radius<=0;state<=1;
    end
    1:begin
     // Root of (index/32)*2^52 is r in Q26; no float or division IP.
     radicand<={6'b0,index,47'b0};root<=0;root_rem<=0;step<=0;
     u<=$signed({1'b0,index,21'b0});state<=2;
    end
    2:begin
     radicand<=radicand<<2;
     if(sr>=trial)begin root_rem<=sr-trial;root<=(root<<1)|1;end
     else begin root_rem<=sr;root<=root<<1;end
     if(step==31)state<=3;else step<=step+1'b1;
    end
    3:begin
     r<=root;
     if(kind==2 && index!=0)begin cx<=ONE;cy<=root;z<=0;step<=0;state<=4;end
     else begin base_scale<=ONE;poly<=kind==1?c2:ONE;state<=8;end
    end
    4:begin
     if(cy>=0)begin cx<=cx+(cy>>>step);cy<=cy-(cx>>>step);z<=z+atan_step(step);end
     else begin cx<=cx-(cy>>>step);cy<=cy+(cx>>>step);z<=z-atan_step(step);end
     if(step==23)state<=5;else step<=step+1'b1;
    end
    5:begin
     theta<=z;product<=z*z;dividend<={6'b0,z[31:0],26'b0};
     divisor<=r;divide_rem<=0;quotient<=0;step<=0;state<=6;
    end
    6:begin
     dividend<=dividend<<1;
     if(dr>={1'b0,divisor})begin divide_rem<=dr-divisor;quotient<=(quotient<<1)|1;end
     else begin divide_rem<=dr;quotient<=quotient<<1;end
     if(step==63)state<=7;else step<=step+1'b1;
    end
    7:begin u<=product>>>26;base_scale<=quotient;poly<=c4;state<=8;end
    8:begin product<=poly*u;state<=9;end
    9:begin
     if(kind==2 && index!=0)poly<=(product>>>26)+c3;
     else if(kind==1)poly<=(product>>>26)+c1;
     else poly<=ONE;
     state<=10;
    end
    10:begin product<=poly*u;state<=11;end
    11:begin
     if(kind==2 && index!=0)poly<=(product>>>26)+c2;
     else if(kind==1)poly<=(product>>>26)+ONE;
     else poly<=ONE;
     state<=12;
    end
    12:begin product<=poly*u;state<=13;end
    13:begin
     if(kind==2 && index!=0)poly<=(product>>>26)+c1;
     state<=14;
    end
    14:begin product<=poly*u;state<=15;end
    15:begin
     if(kind==2 && index!=0)poly<=(product>>>26)+ONE;
     state<=16;
    end
    16:begin product<=poly*base_scale;state<=17;end
    17:begin
     if(product<=0 || (product>>>26)>32'sh7fffffff)begin failed<=1;state<=20;end
     else begin wd<=product>>>26;product<=r*$signed(product[57:26]);state<=18;end
    end
    18:begin
     if(index!=0 && $unsigned(product)<previous_radius)begin failed<=1;state<=20;end
     else begin
      previous_radius<=product;wa<={bank,index};write_entry<=1;
      if(index==1024)state<=20;else begin index<=index+1'b1;state<=1;end
     end
    end
    20:begin busy<=0;done<=1;state<=0;end
    default:begin busy<=0;failed<=1;done<=1;state<=0;end
   endcase
  end
endmodule
