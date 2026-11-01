`timescale 1ns/1ps
// Purpose: apply either fixed gray highlight compression or a legacy manual
// tone curve after the existing
// RGB888 quantization and before SRC storage. Three ROM reads replace the
// geometry sampler's twelve reads. The caller holds mode/curve for the frame;
// coordinates, validity and mask travel with each accepted pixel under stalls.
module rgb_source_gamma #(parameter TAG_BITS=32,parameter FIXED_HIGHLIGHT=0)(
 input clk,rst_n,input [1:0] frame_mode,frame_curve,
 input in_valid,output in_ready,input [23:0] in_rgb,input in_mask,
 input [TAG_BITS-1:0] in_tag,
 output reg out_valid,input out_ready,output reg [23:0] out_rgb,
 output reg out_mask,output reg [TAG_BITS-1:0] out_tag,
 output reg config_rejected
);
 wire advance=!out_valid || out_ready;
 wire configuration_legal=FIXED_HIGHLIGHT || (frame_mode<2 && frame_curve<3);
 wire [23:0] mapped_rgb;
 // Fixed profile: preserve [0,192] exactly, compress the upper range by
 // one half with round-half-up; 255 maps to 224. Input lanes are equal gray.
 // No curve selector, LUT memory, or live mode bypass remains in this branch.
 generate if(FIXED_HIGHLIGHT)begin: fixed_highlight
  wire [7:0] level=in_rgb[7:0];
  wire [8:0] upper={1'b0,level}-9'd192;
  wire [7:0] mapped=level<=192 ? level : 8'd192+((upper+9'd1)>>1);
  assign mapped_rgb={mapped,mapped,mapped};
 end else begin: manual_curves
  genvar channel;
  for(channel=0;channel<3;channel=channel+1)begin: rgb_rom
   tone_builtin_lut curve(.curve(frame_curve),.address(in_rgb[channel*8+:8]),
    .value(mapped_rgb[channel*8+:8]));
  end
 end endgenerate
 assign in_ready=advance;
 // Only validity/mask and the diagnostic pulse reset. The payload remains
 // inaccessible until a complete accepted pixel overwrites all of its fields.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin out_valid<=0;out_mask<=0;config_rejected<=0;end
  else begin
   config_rejected<=in_valid && in_ready && !configuration_legal;
   if(advance)begin
    out_valid<=in_valid;
    out_mask<=in_mask && configuration_legal;
   end
  end
 end
 always @(posedge clk)begin
  if(rst_n && in_valid && in_ready)begin
   out_rgb<=(in_mask && configuration_legal) ?
    (FIXED_HIGHLIGHT ? mapped_rgb : (frame_mode==0 ? in_rgb : mapped_rgb)) : 24'd0;
   out_tag<=in_tag;
  end
 end
endmodule

// Fixed integer luminance with a single elastic register. Shift/add weights
// sum to 256, so neutral RGB values are bit-exact and no multiplier is needed.
// A stalled output holds pixel, coordinate tag and mask together.
module rgb_to_gray #(parameter TAG_BITS=32)(
 input clk,rst_n,in_valid,output in_ready,input [23:0] in_rgb,input in_mask,
 input [TAG_BITS-1:0] in_tag,output reg out_valid,input out_ready,
 output reg [23:0] out_rgb,output reg out_mask,output reg [TAG_BITS-1:0] out_tag
);
 wire [15:0] r={8'd0,in_rgb[23:16]},g={8'd0,in_rgb[15:8]},b={8'd0,in_rgb[7:0]};
 wire [15:0] sum=(r<<6)+(r<<3)+(r<<2)+r+(g<<7)+(g<<4)+(g<<2)+(g<<1)+(b<<4)+(b<<3)+(b<<2)+b+16'd128;
 wire [7:0] gray=sum[15:8];
 assign in_ready=!out_valid || out_ready;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin out_valid<=0;out_mask<=0;end
  else if(in_ready)begin out_valid<=in_valid;out_mask<=in_mask;end
 end
 always @(posedge clk)begin
  if(rst_n && in_valid && in_ready)begin out_rgb<=in_mask?{gray,gray,gray}:24'd0;out_tag<=in_tag;end
 end
endmodule
