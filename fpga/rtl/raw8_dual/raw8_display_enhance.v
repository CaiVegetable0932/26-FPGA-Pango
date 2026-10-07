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
 // Purpose: elaborate the UNCHANGED two-endpoint tone formula into a 256x8
 // combinational ROM. No frame classification, new rounding or pipeline
 // delay is added. PDS 2022.2-SP6.4 ADS guide section 5.18 documents lut_rom;
 // distributed ROM avoids the prior cascaded subtract/add/mux critical path.
 function [7:0] tone_value;
  input [7:0] v;
  reg [7:0] bright,dark,d;
  reg [8:0] sum;
  begin
   if(v<=24)bright=0;
   else if(v<=80)begin d=v-8'd24;bright=d<<1;end
   else if(v<=144)begin d=v-8'd80;bright=8'd112+d+(d>>2);end
   else if(v==255)bright=255;
   else begin d=v-8'd144;bright=8'd192+(d>>1)+(d>>4)+(d>>6);end
   if(v<=8)dark=0;
   else if(v<=16)begin d=v-8'd8;dark=d<<2;end
   else if(v<=32)begin d=v-8'd16;dark=8'd32+(d<<3)-d;end
   else if(v<=64)begin d=v-8'd32;dark=8'd144+(d<<1);end
   else if(v<=128)begin d=v-8'd64;dark=8'd208+(d>>1);end
   else if(v<=240)begin d=v-8'd128;dark=8'd240+(d>>4);end
   else if(v==255)dark=255;
   else begin d=v-8'd240;dark=8'd247+(d>>1);end
   sum={1'b0,bright}+{1'b0,dark}+9'd1;tone_value=sum[8:1];
  end
 endfunction
 reg [7:0] tone_rom[0:255] /* synthesis syn_romstyle="lut_rom" */;
 integer tone_index;
 initial begin
  for(tone_index=0;tone_index<256;tone_index=tone_index+1)
   tone_rom[tone_index]=tone_value(tone_index[7:0]);
 end
 assign luma=tone_rom[selected];
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
