`timescale 1ns/1ps
// Purpose: bounded-I/O harnesses for target-device INTERNAL block PnR only.
// They are never board tops or hardware builds. Serialized live parameters and
// registered input/output boundaries retain the arithmetic instead of optimizing
// it into constants, while staying within the PG2L100H physical I/O count.
module lens_timing_top(
 input clk,rst_n,input [95:0] input_word,input [7:0] control,
 output reg [95:0] output_word,output reg [7:0] status
);
 reg [95:0] data;
 reg [7:0] ctrl;
 reg [287:0] config_words;
 wire ir,ov,mask,ok;wire signed [27:0] u,v;wire [15:0] tag;
 lens_inverse_map #(.TAG_BITS(16)) u_algorithm(.clk(clk),.rst_n(rst_n),.in_valid(ctrl[0]),.in_ready(ir),
  .in_x(data[23:0]),.in_y(data[47:24]),.in_ok(ctrl[4]),.in_tag(data[63:48]),
  .k1(config_words[0+:32]),.k2(config_words[32+:32]),.p1(config_words[64+:32]),.p2(config_words[96+:32]),
  .fx(config_words[128+:32]),.fy(config_words[160+:32]),.cx(config_words[192+:32]),.cy(config_words[224+:32]),
  .width(config_words[256+:16]),.height(config_words[272+:16]),.out_valid(ov),.out_ready(ctrl[1]),
  .out_u(u),.out_v(v),.out_mask(mask),.out_ok(ok),.out_tag(tag));
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin data<=0;ctrl<=0;config_words<=0;output_word<=0;status<=0;end
  else begin
   data<=input_word;ctrl<=control;
   if(ctrl[2]) config_words<={data[31:0],config_words[287:32]};
   output_word<={24'd0,tag,v,u};status<={4'd0,ok,mask,ov,ir};
  end
 end
endmodule

// Whole algorithm harness: dynamic frame coefficients, shadow LUT writes and
// four-bank refill responses. DMA/CDC/HDMI/RAW networking remain outside scope.
module geometry_timing_top(
 input clk,rst_n,input [95:0] input_word,input [7:0] control,
 output reg [95:0] output_word,output reg [7:0] status
);
 reg [95:0] data;reg [7:0] ctrl;reg [703:0] config_words;
 wire frame_ready,ov,mask,req,fill_ready,done,failed,rejected;
 wire [23:0] rgb;wire [15:0] u,v;wire [159:0] frame_identity;wire [15:0] tag;wire [11:0] tx,ty;
 wire [31:0] version,misses,stalls;wire [63:0] bytes_count;wire [15:0] peak;
 // Serialize and observe ALL 160 identity bits, matching the production default.
 // XOR is only an observation harness checksum, never a frame-ID truncation.
 assign tag=frame_identity[15:0]^frame_identity[31:16]^frame_identity[47:32]^frame_identity[63:48]^
  frame_identity[79:64]^frame_identity[95:80]^frame_identity[111:96]^frame_identity[127:112]^frame_identity[143:128]^frame_identity[159:144];
 geometry_rgb_pipeline #(.FRAME_TAG_BITS(160)) u_algorithm(
  .clk(clk),.rst_n(rst_n),.frame_valid(ctrl[1]),.frame_ready(frame_ready),
  .frame_width(config_words[448+:16]),.frame_height(config_words[464+:16]),.frame_coefficients(config_words[447:0]),
  .frame_tag(config_words[512+:160]),.frame_enhancement(config_words[480+:2]),.frame_lut_version(config_words[672+:32]),
  .lut_write(ctrl[2]),.lut_addr(data[7:0]),.lut_data(data[15:8]),.lut_commit(ctrl[6]),.lut_version(config_words[672+:32]),
  .out_valid(ov),.out_ready(ctrl[0]),.out_rgb(rgb),.out_mask(mask),.out_u(u),.out_v(v),.out_frame_tag(frame_identity),
  .fill_req_valid(req),.fill_req_ready(ctrl[3]),.fill_tile_x(tx),.fill_tile_y(ty),
  .fill_valid(ctrl[4]),.fill_ready(fill_ready),.fill_rgb(data),.fill_last(ctrl[5]),.fill_error(data[95]),.fill_bus_bytes(data[31:0]),
  .frame_done(done),.frame_failed(failed),.config_rejected(rejected),.active_lut_version(version),.cache_misses(misses),
  .cache_stalls(stalls),.cache_bus_bytes(bytes_count),.queue_peak(peak));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin data<=0;ctrl<=0;config_words<=0;output_word<=0;status<=0;end
  else begin
   data<=input_word;ctrl<=control;if(ctrl[7])config_words<={data[31:0],config_words[703:32]};
   output_word<={ty,tx,u,v,tag,rgb};status<={failed,rejected,done,frame_ready,req,fill_ready,mask,ov};
  end
 end
endmodule

module bilinear_timing_top(
 input clk,rst_n,input [95:0] input_word,input [7:0] control,
 output reg [95:0] output_word,output reg [7:0] status
);
 reg [95:0] data;reg [7:0] ctrl;reg [39:0] parameters;
 wire ir,ov,mask;wire [23:0] rgb;wire [15:0] tag;
 rgb_bilinear #(.TAG_BITS(16)) u_algorithm(.clk(clk),.rst_n(rst_n),.in_valid(ctrl[0]),.in_ready(ir),.in_samples(data),
  .in_a(parameters[11:0]),.in_b(parameters[23:12]),.in_mask(ctrl[4]),.in_tag(parameters[39:24]),
  .out_valid(ov),.out_ready(ctrl[1]),.out_rgb(rgb),.out_mask(mask),.out_tag(tag));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin data<=0;ctrl<=0;parameters<=0;output_word<=0;status<=0;end
  else begin
   data<=input_word;ctrl<=control;if(ctrl[2])parameters<=data[39:0];
   output_word<={56'd0,tag,rgb};status<={5'd0,mask,ov,ir};
  end
 end
endmodule

module isp_timing_top(
 input clk,rst_n,input [95:0] input_word,input [7:0] control,
 output reg [95:0] output_word,output reg [7:0] status
);
 reg [95:0] data;reg [7:0] ctrl;reg [159:0] config_words;
 wire ir,ov,mask,fs,el,last,error,rejected,fr;wire [23:0] rgb;wire [35:0] linear_rgb;wire [15:0] x,y,tag;
 raw8_isp #(.TAG_BITS(16)) u_algorithm(.clk(clk),.rst_n(rst_n),.frame_start(ctrl[3]),.frame_ready(fr),
  .frame_width(config_words[15:0]),.frame_height(config_words[31:16]),.frame_bayer(config_words[33:32]),
  .black_levels(config_words[64+:32]),.colour_gains(config_words[96+:64]),.frame_tag(config_words[48+:16]),
  .frame_abort(ctrl[7]),.in_valid(ctrl[0]),.in_ready(ir),.in_raw(data[7:0]),.in_sof(ctrl[4]),.in_eol(ctrl[5]),
  .out_valid(ov),.out_ready(ctrl[1]),.out_rgb(rgb),.out_linear_rgb(linear_rgb),.out_x(x),.out_y(y),.out_sof(fs),.out_eol(el),
  .out_last(last),.out_mask(mask),.out_tag(tag),.frame_error(error),.config_rejected(rejected));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin data<=0;ctrl<=0;config_words<=0;output_word<=0;status<=0;end
  else begin
   data<=input_word;ctrl<=control;if(ctrl[2])config_words<={data[31:0],config_words[159:32]};
   output_word<={24'd0,tag,y,x,rgb};status<={rejected,error,fr,last,el,fs,ov,ir};
  end
 end
endmodule
