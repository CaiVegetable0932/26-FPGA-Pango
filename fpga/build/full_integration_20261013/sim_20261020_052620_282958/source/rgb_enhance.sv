`timescale 1ns/1ps
// Purpose: frame-locked disabled/pre/post Gamma around the same bilinear core.
// Twelve physically independent table lanes support 12 addresses per II=1 input.
// The caller ends a frame only after its expected outputs and all DMA writes drain.
module rgb_enhance #(parameter TAG_BITS=192)(
 input clk,rst_n,input frame_start,output frame_ready,output frame_config_ready,input frame_end,
 input [1:0] frame_mode,input [31:0] frame_lut_version,
 input lut_write,input [7:0] lut_addr,lut_data,
 input lut_commit,input [31:0] lut_version,output reg config_rejected,
 input in_valid,output in_ready,input [95:0] in_samples,
 input [11:0] in_a,in_b,input in_mask,input [TAG_BITS-1:0] in_tag,
 output out_valid,input out_ready,output [23:0] out_rgb,
 output out_mask,output [TAG_BITS-1:0] out_tag,
 output reg [31:0] active_lut_version
);
 wire [7:0] gamma_q[0:11];
 reg [255:0] written;
 reg active_page,pending_page,table_valid,busy;
 reg [1:0] mode;
 reg [31:0] pending_version;
 reg pre_valid,pre_mask;
 reg [95:0] pre_raw;
 wire [95:0] pre_samples;
 reg [11:0] pre_a,pre_b;
 reg [TAG_BITS-1:0] pre_tag;
 wire core_ready,core_valid,core_mask;
 wire [23:0] core_rgb;
 wire [TAG_BITS-1:0] core_tag;
 reg post_valid,post_mask;
 reg [23:0] post_rgb;
 reg [TAG_BITS-1:0] post_tag;
 wire post_ready=!post_valid || out_ready;
 wire pre_ready=!pre_valid || core_ready;
 reg [15:0] pipe_count;
 wire drained=!pre_valid && !core_valid && !post_valid && pipe_count==0;
 wire write_allowed=lut_write && frame_ready && !frame_start && !lut_commit;
 genvar gamma_lane;
 generate for(gamma_lane=0;gamma_lane<12;gamma_lane=gamma_lane+1) begin:g_lut
  wire [7:0] address;
  wire read_enable;
  if(gamma_lane<3) begin
   assign address=mode==2 ? core_rgb[gamma_lane*8+:8] : in_samples[gamma_lane*8+:8];
   assign read_enable=busy && ((mode==1 && in_valid && in_ready) || (mode==2 && core_valid && post_ready));
  end else begin
   assign address=in_samples[gamma_lane*8+:8];
   assign read_enable=busy && mode==1 && in_valid && in_ready;
  end
  gamma_lut_bank u_bank(.clk(clk),.read_enable(read_enable),.read_address({active_page,address}),.q(gamma_q[gamma_lane]),
   .write_enable(write_allowed),.write_address({!active_page,lut_addr}),.data(lut_data));
  assign pre_samples[gamma_lane*8+:8]=mode==1 ? gamma_q[gamma_lane] : pre_raw[gamma_lane*8+:8];
 end endgenerate
 integer i;
 assign frame_ready=!busy && drained;
 assign frame_config_ready=frame_ready && frame_mode<3 &&
  (frame_mode==0 || (table_valid && frame_lut_version==pending_version)) && !lut_commit && !lut_write;
 assign in_ready=busy && pre_ready;
 assign out_valid=post_valid,out_rgb=mode==2 ? (post_mask ? {gamma_q[2],gamma_q[1],gamma_q[0]} : 24'd0) : post_rgb;
 assign out_mask=post_mask,out_tag=post_tag;
 rgb_bilinear #(.TAG_BITS(TAG_BITS)) u_core(
  .clk(clk),.rst_n(rst_n),.in_valid(pre_valid),.in_ready(core_ready),
  .in_samples(pre_samples),.in_a(pre_a),.in_b(pre_b),.in_mask(pre_mask),.in_tag(pre_tag),
  .out_valid(core_valid),.out_ready(post_ready),.out_rgb(core_rgb),.out_mask(core_mask),.out_tag(core_tag));
 // Shadow writes replicate the same immutable curve. A complete 256-entry page
 // is required before activation; no configuration is accepted during a frame.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   active_page<=0;pending_page<=0;table_valid<=0;busy<=0;written<=0;
   mode<=0;active_lut_version<=0;pending_version<=0;config_rejected<=0;pipe_count<=0;
   pre_valid<=0;post_valid<=0;pre_mask<=0;post_mask<=0;
  end else begin
   config_rejected<=0;
   if(lut_write) begin
    if(frame_ready && !frame_start && !lut_commit) begin
     written[lut_addr]<=1;
     // A partly rewritten pending page is never eligible for frame activation.
     table_valid<=0;
    end else config_rejected<=1;
   end
   if(lut_commit) begin
    if(frame_ready && !frame_start && !lut_write && &written) begin
     pending_page<=!active_page;pending_version<=lut_version;table_valid<=1;written<=0;
    end else config_rejected<=1;
   end
   if(frame_start) begin
    if(frame_ready && frame_mode<3 && (frame_mode==0 || (table_valid && frame_lut_version==pending_version)) && !lut_commit && !lut_write) begin
     busy<=1;mode<=frame_mode;active_page<=pending_page;
     active_lut_version<=frame_mode==0 ? 0 : frame_lut_version;
    end else config_rejected<=1;
   end
   if(frame_end) begin
    if(busy && drained && !in_valid) busy<=0;
    else config_rejected<=1;
   end
   case({in_valid && in_ready,out_valid && out_ready})
    2'b10:pipe_count<=pipe_count+1'b1;
    2'b01:pipe_count<=pipe_count-1'b1;
    default: ;
   endcase
   if(pre_ready) begin
    pre_valid<=in_valid && in_ready;pre_mask<=in_mask;
    pre_a<=in_a;pre_b<=in_b;pre_tag<=in_tag;
    pre_raw<=in_samples;
   end
   if(post_ready) begin
    post_valid<=core_valid;post_mask<=core_mask;post_tag<=core_tag;
    post_rgb<=core_mask ? core_rgb : 24'd0;
   end
  end
 end
endmodule
