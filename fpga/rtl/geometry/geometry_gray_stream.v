// Purpose: throughput-one exact scalar-baseline arithmetic with independent
// registers for byte extraction, tone, four 2x2 sums, differences, multipliers,
// row sums and final rounding. A global clock enable freezes all data/context
// under result backpressure; the cache may still finish its reserved response.
module geometry_gray_stream(
 input wire clk,rst_n,request_valid,source_valid,enhance,
 input wire [71:0] samples,input wire [11:0] frac_x,frac_y,
 output wire request_ready,result_valid,input wire result_ready,
 output wire [7:0] pixel,output wire mask_valid,busy
);
 reg [9:0] valid_q,mask_q;wire advance=!valid_q[9] || result_ready;
 assign request_ready=advance,result_valid=valid_q[9],mask_valid=mask_q[9];
 assign busy=|valid_q;
 // Purpose: retain the cache-to-tone register boundary in the physical
 // implementation. ADS otherwise absorbs raw_q into tone ROM addressing,
 // joining the large cache byte mux and ROM across a long routed path.
 // Official ADS 5.1/5.15: preserve registers and disallow local retiming;
 // this changes no RTL latency, clock enable, rounding or output bytes.
 (* syn_preserve=1, syn_allow_retiming=0 *) reg [71:0] raw_q;
 reg [71:0] tone_q;reg enhance_q;
 reg [11:0] fx[0:3],fy[0:7];
 reg [7:0] a00,a10,a01,a11,b00,b01,c00,c01;
 reg signed [8:0] dx0,dx1;
 reg signed [21:0] product0,product1;
 reg [19:0] top,bottom,top_delay;
 reg signed [20:0] dy;
 reg signed [33:0] product_y;reg [31:0] top_scaled;
 reg [33:0] rounded;reg [7:0] answer;
 assign pixel=answer;
 wire [71:0] enhanced;
 genvar lane;
 // Purpose: use the existing, unchanged tone ROM with history held empty,
 // exactly as the scalar random-access sampler does, once per RAW sample.
 generate for(lane=0;lane<9;lane=lane+1)begin: curves
  raw8_display_enhance u_curve(.clk(clk),.reset_n(rst_n),.line_active(1'b0),
   .line_end(1'b0),.pixel_accept(1'b0),.sample(raw_q[lane*8+:8]),.luma(enhanced[lane*8+:8]));
 end endgenerate
 function [7:0] average;
  input [7:0] a,b,c,d;reg [9:0] sum;
  begin sum={2'b0,a}+b+c+d+10'd2;average=sum[9:2];end
 endfunction
 wire signed [21:0] top_sum=$signed({2'b0,c00,12'b0})+product0;
 wire signed [21:0] bottom_sum=$signed({2'b0,c01,12'b0})+product1;
 integer k;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin valid_q<=0;mask_q<=0;end
  else if(advance)begin
   valid_q<={valid_q[8:0],request_valid};mask_q<={mask_q[8:0],source_valid};
  end
 // Purpose: datapath registers need no reset; valid_q protects every result.
 // Signed guard widths preserve the scalar algebra without intermediate
 // rounding: row=4096*a+frac*(b-a); final rounding is exactly +2^23.
 always @(posedge clk)if(advance)begin
  raw_q<=samples;enhance_q<=enhance;fx[0]<=frac_x;fy[0]<=frac_y;
  for(k=1;k<4;k=k+1)fx[k]<=fx[k-1];
  for(k=1;k<8;k=k+1)fy[k]<=fy[k-1];
  tone_q<=enhance_q?enhanced:raw_q;
  a00<=average(tone_q[0*8+:8],tone_q[1*8+:8],tone_q[3*8+:8],tone_q[4*8+:8]);
  a10<=average(tone_q[1*8+:8],tone_q[2*8+:8],tone_q[4*8+:8],tone_q[5*8+:8]);
  a01<=average(tone_q[3*8+:8],tone_q[4*8+:8],tone_q[6*8+:8],tone_q[7*8+:8]);
  a11<=average(tone_q[4*8+:8],tone_q[5*8+:8],tone_q[7*8+:8],tone_q[8*8+:8]);
  dx0<=$signed({1'b0,a10})-$signed({1'b0,a00});
  dx1<=$signed({1'b0,a11})-$signed({1'b0,a01});b00<=a00;b01<=a01;
  product0<=$signed({1'b0,fx[3]})*dx0;product1<=$signed({1'b0,fx[3]})*dx1;
  c00<=b00;c01<=b01;
  top<=top_sum[19:0];bottom<=bottom_sum[19:0];
  dy<=$signed({1'b0,bottom})-$signed({1'b0,top});top_delay<=top;
  product_y<=$signed({1'b0,fy[6]})*dy;top_scaled<={top_delay,12'b0};
  rounded<=$signed({2'b0,top_scaled})+product_y+34'sd8388608;
  answer<=mask_q[8]?rounded[31:24]:8'd0;
 end
endmodule
