`timescale 1ns/1ps
// Purpose: normalized ideal rays -> distorted source S(28,12), II=1, 23 stages.
// S(24,20) rays; squares/r2 S(32,20); Horner/radial S(32,26);
// tangential/distorted rays S(32,20); K S(32,16). Parameters are frame-constant.
// All full products use independently pipelined native-sized partial products.
// Arithmetic/gating/identity freeze together; overflow invalidates the lane.
module lens_inverse_map #(parameter TAG_BITS=192)(
 input clk,rst_n,input in_valid,output in_ready,
 input signed [23:0] in_x,in_y,input in_ok,input [TAG_BITS-1:0] in_tag,
 input signed [31:0] k1,k2,p1,p2,fx,fy,cx,cy,
 input [15:0] width,height,
 output out_valid,input out_ready,output reg signed [27:0] out_u,out_v,
 output out_mask,out_ok,output [TAG_BITS-1:0] out_tag
);
 reg [22:0] valid,ok;
 wire [TAG_BITS-1:0] delayed_tag;
 reg signed [23:0] x_first,y_first; wire signed [23:0] x_last,y_last;
 reg signed [31:0] xx,yy,xy,xx5,yy5,xy5,r2[0:4],arg_x,arg_y;
 reg signed [31:0] t,radial,xd,yd; wire signed [31:0] tx_last,ty_last;
 reg signed [63:0] tx_xy,ty_xy,us,vs;
 wire signed [63:0] xx_raw,yy_raw,xy_raw,horner_raw,tx0_raw,ty0_raw,tx1_raw,ty1_raw;
 wire signed [63:0] radial_raw,xr,yr,up,vp;
 wire advance=!valid[22] || out_ready;
 wire signed [63:0] xx_round=(xx_raw+64'sd524288)>>>20;
 wire signed [63:0] yy_round=(yy_raw+64'sd524288)>>>20;
 wire signed [63:0] xy_round=(xy_raw+64'sd524288)>>>20;
 wire signed [63:0] r2_sum=$signed({{32{xx[31]}},xx})+$signed({{32{yy[31]}},yy});
 wire signed [63:0] horner_round=((horner_raw+64'sd524288)>>>20)+$signed(k1);
 wire signed [63:0] tx_round=(tx_xy<<<1)+((tx1_raw+64'sd33554432)>>>26);
 wire signed [63:0] ty_round=(ty_xy<<<1)+((ty1_raw+64'sd33554432)>>>26);
 wire signed [63:0] radial_round=((radial_raw+64'sd524288)>>>20)+64'sd67108864;
 wire signed [63:0] xd_round=((xr+64'sd33554432)>>>26)+$signed(tx_last);
 wire signed [63:0] yd_round=((yr+64'sd33554432)>>>26)+$signed(ty_last);
 wire signed [63:0] u_round=(us+64'sd8388608)>>>24,v_round=(vs+64'sd8388608)>>>24;

 // Purpose: preserve 14/23/7 accepted-advance alignment using LUT RAM
 // (installed ADS 5.16). Nonzero read offsets avoid write/read collisions.
 // Public validity flushes stale entries after pointer reset; all payload
 // writes/reads freeze under the original common stall/reset guard.
 reg [4:0] payload_write;
 wire [4:0] xy_read=payload_write-5'd13;
 wire [4:0] tag_read=payload_write-5'd22;
 wire [4:0] tangent_read=payload_write-5'd6;
 reg [47:0] xy_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [TAG_BITS-1:0] tag_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [63:0] tangent_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [47:0] xy_output;
 reg [TAG_BITS-1:0] tag_output;
 reg [63:0] tangent_output;
 assign {x_last,y_last}=xy_output;
 assign delayed_tag=tag_output;
 assign {tx_last,ty_last}=tangent_output;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) payload_write<=0;
  else if(advance) payload_write<=payload_write+1'b1;
 end
 always @(posedge clk) if(rst_n && advance) begin
  xy_memory[payload_write]<={in_x,in_y};
  tag_memory[payload_write]<=in_tag;
  tangent_memory[payload_write]<={tx_round[31:0],ty_round[31:0]};
  xy_output<=xy_memory[xy_read];
  tag_output<=tag_memory[tag_read];
  tangent_output<=tangent_memory[tangent_read];
 end
 integer i;
 function fits32(input signed [63:0] value);
  begin fits32=value>=-64'sd2147483648 && value<64'sd2147483648;end
 endfunction
 assign in_ready=advance,out_valid=valid[22],out_tag=delayed_tag,out_ok=ok[22];
 assign out_mask=ok[22] && out_u>=0 && out_v>=0 &&
  $signed(out_u)<=($signed({1'b0,width})-1)*4096 && $signed(out_v)<=($signed({1'b0,height})-1)*4096;
 // Stage indices refer to accepted clock-enable advances, not wall-clock cycles.
 // 1..3 squares; 6..8 Horner/xy; 7..9 tangent arguments; 10..12 radial;
 // 14..16 distorted rays; 18..20 final projection. Products remain 64 bits.
 signed_mult32_pipe m_xx(clk,advance,{{8{x_first[23]}},x_first},{{8{x_first[23]}},x_first},xx_raw);
 signed_mult32_pipe m_yy(clk,advance,{{8{y_first[23]}},y_first},{{8{y_first[23]}},y_first},yy_raw);
 signed_mult32_pipe m_xy(clk,advance,{{8{x_first[23]}},x_first},{{8{y_first[23]}},y_first},xy_raw);
 signed_mult32_pipe m_horner(clk,advance,r2[0],k2,horner_raw);
 signed_mult32_pipe m_tx0(clk,advance,xy5,p1,tx0_raw);
 signed_mult32_pipe m_ty0(clk,advance,xy5,p2,ty0_raw);
 signed_mult32_pipe m_tx1(clk,advance,arg_x,p2,tx1_raw);
 signed_mult32_pipe m_ty1(clk,advance,arg_y,p1,ty1_raw);
 signed_mult32_pipe m_radial(clk,advance,r2[4],t,radial_raw);
 signed_mult32_pipe m_xr(clk,advance,{{8{x_last[23]}},x_last},radial,xr);
 signed_mult32_pipe m_yr(clk,advance,{{8{y_last[23]}},y_last},radial,yr);
 signed_mult32_pipe m_up(clk,advance,xd,fx,up);
 signed_mult32_pipe m_vp(clk,advance,yd,fy,vp);
 // Lane validity/overflow and public coordinates retain their asynchronous
 // reset contract; invalid lanes mask all unreset arithmetic/tag payload.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin valid<=0;ok<=0;out_u<=0;out_v<=0;end
  else if(advance) begin
   valid<={valid[21:0],in_valid};ok<={ok[21:0],in_ok};
   ok[4]<=ok[3] && fits32(xx_round) && fits32(yy_round) && fits32(xy_round);
   ok[5]<=ok[4] && fits32(r2_sum);
   ok[9]<=ok[8] && fits32(horner_round);
   ok[10]<=ok[9] && fits32(tx_round) && fits32(ty_round);
   ok[13]<=ok[12] && fits32(radial_round);
   ok[17]<=ok[16] && fits32(xd_round) && fits32(yd_round);
   out_u<=u_round[27:0];out_v<=v_round[27:0];
   ok[22]<=ok[21] && u_round>=-64'sd134217728 && u_round<64'sd134217728 && v_round>=-64'sd134217728 && v_round<64'sd134217728;
  end
 end
 // Separate unreset payload from resettable control so ADS can pack clock
 // enables without adding asynchronous-reset hold feedback muxes. Preserve
 // the old reset hold and use the common advance for data/tag alignment.
 always @(posedge clk) begin
  if(rst_n && advance) begin
   x_first<=in_x;y_first<=in_y;
   xx<=xx_round[31:0];yy<=yy_round[31:0];xy<=xy_round[31:0];
   xx5<=xx;yy5<=yy;xy5<=xy;r2[0]<=r2_sum[31:0];
   for(i=1;i<5;i=i+1) r2[i]<=r2[i-1];
   // With S(24,20) rays, r2+2*xx/yy <=256 normalized units:
   // pre-multiply arguments fit S(32,20), without calibration-specific clipping.
   arg_x<=r2[0]+(xx5<<<1);arg_y<=r2[0]+(yy5<<<1);
   t<=horner_round[31:0];
   tx_xy<=(tx0_raw+64'sd33554432)>>>26;ty_xy<=(ty0_raw+64'sd33554432)>>>26;
   radial<=radial_round[31:0];
   xd<=xd_round[31:0];yd<=yd_round[31:0];
   us<=up+($signed({{32{cx[31]}},cx})<<<20);vs<=vp+($signed({{32{cy[31]}},cy})<<<20);
  end
 end
endmodule
