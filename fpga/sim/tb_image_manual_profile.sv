`timescale 1ns/1ps
// Manual-profile capability regression: rejected automatic/custom requests
// must leave last-good entities untouched, while manual source binding works.
module tb_image_manual_profile;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg csubmit=0,ccapture=0,stats=0;reg [511:0] cb=0;reg [31:0] cv=2;
 wire [7:0] ccode;wire [31:0] colour_version,black;wire [63:0] gains;wire [161:0] ccm;wire [2303:0] cs;
 isp_colour_control #(.SUPPORT_AUTO(0)) colour(.clk(clk),.rst_n(rst_n),.submit_valid(csubmit),.body(cb),.version(cv),.entity_id(32'd8),
  .submit_code(ccode),.capture_boundary(ccapture),.epoch(64'd4),.frame_id(64'd12),.capture_version(colour_version),.capture_black(black),.capture_gains(gains),.capture_ccm(ccm),
  .statistics_valid(stats),.red_sum(48'd0),.green_sum(48'd10000),.blue_sum(48'd0),.neutral_count(32'd100),.status(cs));
 reg asubmit=0,acapture=0,adone=0;reg [383:0] ab=0;reg [31:0] av=2;
 wire [7:0] acode;wire [2303:0] ast;wire pause_capture,apply,continuous,stable;wire [19:0] exposure;wire [9:0] gain;wire [31:0] camera_version;
 camera_brightness_control #(.DRAIN_TIMEOUT(1000),.SUPPORT_AUTO(0)) camera(.clk(clk),.rst_n(rst_n),.submit_valid(asubmit),.body(ab),.version(av),.entity_id(32'd5),
  .submit_code(acode),.status(ast),.source_quiesced(1'b1),.pause_capture(pause_capture),.apply_valid(apply),.continuous(continuous),.apply_ready(1'b1),
  .exposure(exposure),.gain(gain),.apply_done(adone),.apply_error(3'd0),.capture_boundary(acapture),.capture_epoch(64'd3),.capture_frame(64'd77),
  .statistics_valid(stats),.luminance_sum(48'd0),.samples(32'd100),.capture_camera_version(camera_version),.auto_stable(stable));
 reg tsubmit=0,tcapture=0;reg [15:0] kind=1,read_kind=1;reg [2047:0] tb=0;reg [31:0] tv=2;
 wire [7:0] tcode;wire [2303:0] ts;wire initialized,programming,write_lut,commit_lut;wire [7:0] addr,data;wire [1:0] mode;wire [31:0] tone_version;
 integer curve=0,writes=0,commits=0;reg [7:0] midpoint;
 tone_entity_control #(.SUPPORT_AUTO(0),.SUPPORT_UPLOAD(0)) tone(.clk(clk),.rst_n(rst_n),.processing_clk(clk),.processing_rst_n(rst_n),
  .submit_valid(tsubmit),.kind(kind),.body(tb),.version(tv),.entity_id(32'd2),.submit_code(tcode),.read_kind(read_kind),.status(ts),
  .legacy_valid(1'b0),.legacy_mode(2'd0),.legacy_version(32'd0),.legacy_ready(),.capture_boundary(tcapture),.epoch(64'd9),.frame_id(64'd1),
  .capture_mode(mode),.capture_version(tone_version),.capture_entity_id(),.capture_lut_version(),.capture_page(),
  .bind_valid(1'b0),.bind_slot(2'd0),.bind_page(1'b0),.release_valid(1'b0),.release_slot(2'd0),.cancel_valid(1'b0),.cancel_slot(2'd0),
  .geometry_idle(1'b1),.programming(programming),.initialized(initialized),.statistics_valid(stats),.luminance_sum(48'd0),.samples(32'd100),
  .lut_write(write_lut),.lut_addr(addr),.lut_data(data),.lut_commit(commit_lut),.lut_page(),.lut_program_version());
 always @(posedge clk)begin
  if(write_lut)begin writes=writes+1;if(addr==128)midpoint=data;end
  if(commit_lut)begin if(writes!=256)$fatal(1,"curve incomplete %d",writes);writes=0;commits=commits+1;end
 end
 task tone_send(input [7:0] expected);
  begin @(negedge clk);#1;if(tcode!==expected)$fatal(1,"tone code %d expected %d",tcode,expected);tsubmit=1;@(negedge clk);tsubmit=0;end
 endtask
 integer n;
 initial begin
  #22;rst_n=1;@(negedge clk);
  cb[32+:64]=64'h1800100010001200;cb[96+:8]=1;cb[128+:32]=16384;cb[256+:32]=16384;cb[384+:32]=16384;
  #1;if(ccode!=0)$fatal(1,"manual colour rejected");csubmit=1;@(negedge clk);csubmit=0;
  if(cs[32+:32]!=1 || !cs[113])$fatal(1,"colour changed before capture");ccapture=1;@(negedge clk);ccapture=0;
  if(cs[32+:32]!=2 || gains!=64'h1800100010001200 || ccm[17:0]!=16384)$fatal(1,"manual colour lost");
  cv=3;cb[104+:8]=1;cb[448+:16]=2048;cb[464+:16]=8192;cb[480+:16]=16;cb[496+:16]=1;
  #1;if(ccode!=11)$fatal(1,"unsupported AWB accepted");csubmit=1;@(negedge clk);csubmit=0;
  ab[23:16]=96;ab[31:24]=144;ab[32+:32]=1000;ab[64+:16]=16;ab[80+:16]=16;ab[96+:16]=32;
  ab[112+:16]=1;ab[128+:32]=16;ab[160+:32]=17856;ab[192+:32]=256;ab[224+:16]=1;ab[240+:16]=2;
  #1;if(acode!=0)$fatal(1,"manual camera rejected");asubmit=1;@(negedge clk);asubmit=0;wait(apply);
  if(!pause_capture || continuous || exposure!=1000 || gain!=16)$fatal(1,"manual camera service differs");
  repeat(2)@(negedge clk);adone=1;@(negedge clk);adone=0;
  if(ast[32+:32]!=1 || camera_version!=2)$fatal(1,"camera early activation");acapture=1;@(negedge clk);acapture=0;
  av=3;for(n=1;n<=2;n=n+1)begin ab[7:0]=n;#1;if(acode!=11)$fatal(1,"unsupported AE accepted");asubmit=1;@(negedge clk);asubmit=0;end
  // The narrowed period validator still accepts all four whole multiples and
  // rejects a high-bit alias even when its low fifteen bits match a valid one.
  ab[7:0]=0;ab[15:8]=1;ab[256+:32]=52000;ab[288+:32]=2051;ab[320+:32]=1;
  for(n=1;n<=4;n=n+1)begin ab[32+:32]=2051*n;ab[128+:32]=2051;ab[160+:32]=8204;#1;if(acode!=0)$fatal(1,"period multiple %d rejected",n);end
  ab[288+:32]=34819;#1;if(acode!=11)$fatal(1,"high-bit period alias accepted");ab[288+:32]=2051;ab[32+:32]=8203;#1;if(acode!=11)$fatal(1,"off-period exposure accepted");
  wait(initialized);tb[7:0]=1;tb[23:16]=7;tb[39:32]=96;tb[47:40]=144;tb[63:48]=1;
  for(curve=0;curve<3;curve=curve+1)begin
   tb[15:8]=curve;tone_send(0);wait(tone.publish_pending);
   if(midpoint!=(curve==0?157:curve==1?128:104))$fatal(1,"builtin curve midpoint wrong");
   @(negedge clk);tcapture=1;@(negedge clk);tcapture=0;
   if(tone_version!=tv || mode!=1 || ts[256+8+:8]!=curve)$fatal(1,"manual tone binding wrong");tv=tv+1;
  end
  tb[7:0]=2;tone_send(11);tb[7:0]=1;tb[15:8]=3;tone_send(11);kind=2;tone_send(6);
  read_kind=2;#1;if(ts[2303:32]!=0)$fatal(1,"disabled upload claims valid data");read_kind=1;
  // Strongly out-of-target completed statistics cannot resurrect any disabled
  // automatic loop or silently create a source generation.
  repeat(20)begin @(negedge clk);stats=1;@(negedge clk);stats=0;end
  if(cs[32+:32]!=2 || cs[113] || ast[32+:32]!=2 || apply || pause_capture || !stable || tone_version!=4 || programming || commits!=4)$fatal(1,"disabled automatic loop changed state");
  $display("IMAGE_MANUAL_PROFILE_PASS manual source binding, three builtins, rejected AUTO/upload, period guard");$finish;
 end
 initial begin #100000;$fatal(1,"IMAGE_MANUAL_PROFILE_TIMEOUT");end
endmodule
