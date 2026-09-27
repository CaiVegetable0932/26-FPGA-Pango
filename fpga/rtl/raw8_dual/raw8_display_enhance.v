// Purpose: provide the same bounded, line-local FPGA enhancement to HDMI and
// the versioned Ethernet RAW8 output while DDR retains captured S0. A 3-tap median at x,x-2,x-4 uses the same Bayer
// phase to reject isolated hot/corrupt samples. A previous-frame brightness
// dark-pixel majority selects a low-light contrast curve or the proven bright-scene curve;
// no frame buffer, temporal ghosting or variable pixel latency is introduced.
module raw8_display_enhance #(parameter integer MIN_SAMPLES=30000)(
 input wire clk,reset_n,frame_boundary,line_active,line_end,pixel_accept,
 input wire [7:0] sample,output wire [7:0] luma
);
 reg [7:0] prev1,prev2,prev3,prev4;
 reg [2:0] valid_count;
 wire [7:0] same_phase_median = sample>prev2 ?
  (prev2>prev4 ? prev2 : (sample>prev4 ? prev4 : sample)) :
  (sample>prev4 ? sample : (prev2>prev4 ? prev4 : prev2));
 wire [7:0] selected = valid_count==4 ? same_phase_median : sample;
 // Purpose: preserve the previously tested highlight-protecting curve when
 // the sensor scene is bright. This path retains its exact 24/80/144 knees.
 wire [7:0] shadow_delta=selected-8'd24;
 wire [7:0] mid_delta=selected-8'd80;
 wire [7:0] highlight_delta=selected-8'd144;
 wire [7:0] bright_luma = selected<=24 ? 8'd0 :
               selected<=80 ? shadow_delta<<1 :
               selected<=144 ? 8'd112+mid_delta+(mid_delta>>2) :
               selected==255 ? 8'd255 :
               8'd192+(highlight_delta>>1)+(highlight_delta>>4)+(highlight_delta>>6);
 // Purpose: reveal boundaries in the measured dark RAW8 histogram (median
 // 14, p95 46) without turning the 8-code black floor gray. The low-light
 // knees 8/16/32/64/128 map to 0/32/144/208/240, with a monotonic shoulder
 // and the sensor's 255 white code preserved.
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
 reg low_light;
 assign luma=low_light ? dark_luma : bright_luma;
 // Purpose: classify one accepted pixel in 64 as dark when its code is <=64.
 // A majority vote is not biased upward by a small saturated light strip as
 // the former frame mean was. Require a nearly complete frame before changing
 // modes; short/poisoned frames retain the last good setting. Latch only at
 // frame boundary so no line changes tone halfway through.
 reg [5:0] sample_div;
 reg [15:0] sample_count;
 reg [15:0] dark_count;
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n)begin
   sample_div<=0;sample_count<=0;dark_count<=0;low_light<=0;
  end else if(frame_boundary)begin
   if(sample_count>=MIN_SAMPLES)
    low_light<=dark_count>(sample_count>>1);
   sample_div<=0;sample_count<=0;dark_count<=0;
  end else if(pixel_accept)begin
   sample_div<=sample_div+1'b1;
   if(sample_div==0)begin
    sample_count<=sample_count+1'b1;
    if(selected<=8'd64)dark_count<=dark_count+1'b1;
   end
  end
 end
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
