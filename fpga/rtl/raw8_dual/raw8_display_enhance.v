// Purpose: apply one deterministic enhancement to both HDMI and versioned
// Ethernet RAW8 while DDR retains captured S0. The same-Bayer-phase median
// rejects isolated defects; a fixed tone map cannot flip at a frame-darkness
// threshold when exposure or illumination changes slightly.
module raw8_display_enhance(
 input wire clk,reset_n,line_active,line_end,pixel_accept,
 input wire [7:0] sample,output wire [7:0] luma
);
 reg [7:0] prev1,prev2,prev3,prev4;
 reg [2:0] valid_count;
 wire [7:0] same_phase_median = sample>prev2 ?
  (prev2>prev4 ? prev2 : (sample>prev4 ? prev4 : sample)) :
  (sample>prev4 ? sample : (prev2>prev4 ? prev4 : prev2));
 wire [7:0] selected = valid_count==4 ? same_phase_median : sample;
 // Purpose: retain the tested highlight-protecting curve as the low-gain
 // endpoint of a fixed tone map; its 24/80/144 knees protect bright regions.
 wire [7:0] shadow_delta=selected-8'd24;
 wire [7:0] mid_delta=selected-8'd80;
 wire [7:0] highlight_delta=selected-8'd144;
 wire [7:0] bright_luma = selected<=24 ? 8'd0 :
               selected<=80 ? shadow_delta<<1 :
               selected<=144 ? 8'd112+mid_delta+(mid_delta>>2) :
               selected==255 ? 8'd255 :
               8'd192+(highlight_delta>>1)+(highlight_delta>>4)+(highlight_delta>>6);
 // Purpose: retain the tested shadow-revealing curve as the high-gain
 // endpoint. Its monotonic shoulder and 255 white code remain unchanged.
 wire [7:0] low8_delta=selected-8'd8;
 wire [7:0] low16_delta=selected-8'd16;
 wire [7:0] low32_delta=selected-8'd32;
 wire [7:0] low64_delta=selected-8'd64;
 wire [7:0] low128_delta=selected-8'd128;
 wire [7:0] low240_delta=selected-8'd240;
 wire [7:0] dark_luma = selected<=8 ? 8'd0 :
              selected<=16 ? low8_delta<<2 :
              selected<=32 ? 8'd32+(low16_delta<<3)-low16_delta :
              selected<=64 ? 8'd144+(low32_delta<<1) :
              selected<=128 ? 8'd208+(low64_delta>>1) :
              selected<=240 ? 8'd240+(low128_delta>>4) :
              selected==255 ? 8'd255 :
              8'd247+(low240_delta>>1);
 // Purpose: blend both tested endpoints once per pixel, not once per frame.
 // The explicit nine-bit sum prevents overflow near white; rounding keeps
 // the map monotonic and preserves black=0/white=255. No exposure classifier,
 // frame memory, or temporal state remains in this display-only operation.
 wire [8:0] tone_sum={1'b0,bright_luma}+{1'b0,dark_luma}+9'd1;
 assign luma=tone_sum[8:1];
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n)begin prev1<=0;prev2<=0;prev3<=0;prev4<=0;valid_count<=0;end
  // Purpose: the continuous Ethernet byte stream has no horizontal blanking;
  // its final accepted column explicitly clears the same-phase history.
  else if(!line_active || line_end)begin prev1<=0;prev2<=0;prev3<=0;prev4<=0;valid_count<=0;end
  else if(pixel_accept)begin
   prev4<=prev3;prev3<=prev2;prev2<=prev1;prev1<=sample;
   if(valid_count<4)valid_count<=valid_count+1'b1;
  end
 end
endmodule
