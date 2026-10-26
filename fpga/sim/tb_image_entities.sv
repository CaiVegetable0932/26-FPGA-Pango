`timescale 1ns/1ps
// Exercise the real replicated LUT pixel path and source-retention controller,
// including old-source/new-page overlap, BUSY, retries and monotonic rejection.
module tb_image_entities;
 reg clk=0,pclk=0,rst_n=0;always #5 clk=~clk;always #3 pclk=~pclk;
 reg submit=0;reg [15:0] kind=1,read_kind=1;reg [2047:0] body=0;reg [31:0] version=2,id=2;
 wire [7:0] code;wire [2303:0] status;reg boundary=0;reg [63:0] fid=1;
 wire [1:0] mode;wire [31:0] cv,ci,lv;wire page;
 reg bind_source=0,bindpage=0,release_source=0,cancel_source=0;reg [1:0] slot=0,release_slot=0;
 reg legacy=0;reg [1:0] legacy_mode=0;reg [31:0] legacy_version=5;wire legacy_ready;
 reg idle=1,stats=0;reg [47:0] sum=0;reg [31:0] count=100;
 wire programming,initialized,write_lut,commit_lut,write_page;wire [7:0] addr,data;wire [31:0] pv;
 reg start=0,finish=0;reg [31:0] frame_version=1;wire ready,config_ready,rejected;
 reg iv=0;wire ir,ov;reg [95:0] pixels={12{8'd64}};wire [23:0] result;
 tone_entity_control control(.clk(clk),.rst_n(rst_n),.processing_clk(pclk),.processing_rst_n(rst_n),
  .submit_valid(submit),.kind(kind),.body(body),.version(version),.entity_id(id),.submit_code(code),.read_kind(read_kind),.status(status),
  .legacy_valid(legacy),.legacy_mode(legacy_mode),.legacy_version(legacy_version),.legacy_ready(legacy_ready),
  .capture_boundary(boundary),.epoch(64'd9),.frame_id(fid),.capture_mode(mode),.capture_version(cv),.capture_entity_id(ci),.capture_lut_version(lv),.capture_page(page),
  .bind_valid(bind_source),.bind_slot(slot),.bind_page(bindpage),.release_valid(release_source),.release_slot(release_slot),.cancel_valid(cancel_source),.cancel_slot(2'd0),
  .geometry_idle(idle),.programming(programming),.initialized(initialized),.statistics_valid(stats),.luminance_sum(sum),.samples(count),
  .lut_write(write_lut),.lut_addr(addr),.lut_data(data),.lut_commit(commit_lut),.lut_page(write_page),.lut_program_version(pv));
 rgb_enhance #(.TAG_BITS(8),.EXTERNAL_PAGES(1)) pixels_dut(.clk(pclk),.rst_n(rst_n),
  .frame_start(start),.frame_ready(ready),.frame_config_ready(config_ready),.frame_end(finish),.frame_mode(2'd1),.frame_lut_version(frame_version),
  .lut_write(write_lut),.lut_addr(addr),.lut_data(data),.lut_commit(commit_lut),.lut_version(pv),.lut_page(write_page),.config_rejected(rejected),
  .in_valid(iv),.in_ready(ir),.in_samples(pixels),.in_a(12'd0),.in_b(12'd0),.in_mask(1'b1),.in_tag(8'd5),
  .out_valid(ov),.out_ready(1'b1),.out_rgb(result),.out_mask(),.out_tag(),.active_lut_version());
 task send(input [7:0] expected);
  begin @(negedge clk);#1;if(code!==expected)$fatal(1,"code %d expected %d",code,expected);
   submit=1;@(negedge clk);submit=0;end
 endtask
 task capture;
  begin @(negedge clk);boundary=1;@(negedge clk);boundary=0;fid=fid+1;end
 endtask
 task pixel(input [31:0] v,input [7:0] expected);
  begin
   idle=0;frame_version=v;@(negedge pclk);if(!config_ready)$fatal(1,"retained page absent %d",v);
   start=1;@(negedge pclk);start=0;iv=1;@(negedge pclk);iv=0;
   wait(ov);#1;if(result!=={3{expected}})$fatal(1,"pixel %h expected %h",result,expected);
   repeat(4)@(negedge pclk);finish=1;@(negedge pclk);finish=0;idle=1;
  end
 endtask
 integer i;
 initial begin
  #30;rst_n=1;wait(initialized);repeat(3)@(negedge clk);
  read_kind=2;#1;if(status[113] || status[112])$fatal(1,"empty upload buffer incorrectly pending");read_kind=1;
  // Hold a source with the initial gamma=.7 generation while replacing page1.
  bind_source=1;bindpage=0;@(negedge clk);bind_source=0;
  pixel(1,97);
  kind=2;version=7;for(i=0;i<256;i=i+1)body[i*8+:8]=i;send(0);
  read_kind=2;#1;if(!status[113] || !status[112])$fatal(1,"first upload not retained pending");read_kind=1;
  kind=1;version=2;body=0;body[7:0]=1;body[15:8]=3;body[23:16]=7;body[31:24]=4;
  body[39:32]=96;body[47:40]=144;body[63:48]=2;body[95:64]=7;send(0);
  wait(control.publish_pending);capture();
  pixel(1,97);pixel(2,64);
  // Both generations can coexist. The old source forbids page0 reuse.
  version=3;body[15:8]=2;send(4);
  release_source=1;@(negedge clk);release_source=0;send(0);wait(control.publish_pending);capture();pixel(3,42);
  kind=2;version=8;body=0;body[7:0]=255;send(11);
  // AUTO changes a local curve after held completed statistics, with no host.
  kind=1;version=4;body=0;body[7:0]=2;body[15:8]=1;body[23:16]=7;
  body[39:32]=96;body[47:40]=144;body[63:48]=1;send(0);wait(control.publish_pending);capture();
  sum=0;repeat(2)begin @(negedge clk);stats=1;@(negedge clk);stats=0;end
  wait(control.publish_pending);capture();pixel(5,97);
  // Old OFF then ON must preserve the last submitted AUTO policy and use the
  // same bounded pending slot. A new entity transaction blocks legacy acceptance.
  @(negedge clk);legacy=1;@(negedge clk);legacy=0;capture();if(mode!=0)$fatal(1,"legacy OFF failed");
  legacy_version=6;legacy_mode=1;@(negedge clk);legacy=1;@(negedge clk);legacy=0;capture();
  if(control.active_config[7:0]!=2)$fatal(1,"legacy ON lost AUTO policy");
  kind=2;version=9;for(i=0;i<256;i=i+1)body[i*8+:8]=i;
  @(negedge clk);submit=1;#1;if(legacy_ready)$fatal(1,"two tone arbiters accepted concurrently");@(negedge clk);submit=0;
  $display("IMAGE_ENTITIES_PASS old page retained, busy, monotonic, AUTO and real RGB pixels");$finish;
 end
 initial begin #200000;$fatal(1,"IMAGE_ENTITIES_TIMEOUT");end
endmodule

// Matrix coefficient guard and actual RGB12 datapath share one frame-held
// entity, so a queued host update cannot alter pixels in the current capture.
module tb_isp_colour_entity;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg submit=0,boundary=0;reg [511:0] body=0;wire [7:0] code;wire [161:0] ccm;
 wire [31:0] cv,black;wire [63:0] gains;wire [2303:0] status;
 reg awb_stats=0;reg [31:0] neutral_count=15;
 reg [31:0] version=2;reg [161:0] held;reg iv=0;wire ir,ov;wire [23:0] rgb;
 isp_colour_control ctrl(.clk(clk),.rst_n(rst_n),.submit_valid(submit),.body(body),.version(version),.entity_id(32'd8),.submit_code(code),
  .capture_boundary(boundary),.epoch(64'd4),.frame_id(64'd12),.capture_version(cv),.capture_black(black),.capture_gains(gains),.capture_ccm(ccm),
  .statistics_valid(awb_stats),.red_sum(48'd9000),.green_sum(48'd10000),.blue_sum(48'd11000),.neutral_count(neutral_count),.status(status));
 rgb_colour_matrix #(.TAG_BITS(8)) matrix(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(ir),.in_rgb({12'd1600,12'd800,12'd3200}),
  .coefficients(held),.in_tag(8'd0),.in_mask(1'b1),.out_valid(ov),.out_ready(1'b1),.out_rgb(rgb),.out_mask(),.out_tag());
 initial begin
  #22;rst_n=1;@(negedge clk);held=ccm;
  body[32+:64]=64'h1000100010001000;body[96+:8]=1;
  body[128+2*32+:32]=16384;body[128+4*32+:32]=16384;body[128+6*32+:32]=16384;
  #1;if(code!=0)$fatal(1,"valid swap rejected");submit=1;@(negedge clk);submit=0;
  iv=1;@(negedge clk);iv=0;wait(ov);#1;if(rgb!==24'h6432c8)$fatal(1,"queued update changed active RGB12");
  @(negedge clk);held=ccm;boundary=1;@(negedge clk);boundary=0;
  iv=1;@(negedge clk);iv=0;wait(ov);#1;if(rgb!==24'hc83264)$fatal(1,"CCM swap absent");
  version=3;body[128+:32]=131071;body[160+:32]=131071;#1;if(code!=11)$fatal(1,"row sum overflow accepted");
  // Insufficient neutral samples are ignored; then a bounded AWB step alters
  // only R/B on a later source boundary, retaining calibrated green channels.
  body[128+:32]=0;body[160+:32]=0;body[104+:8]=1;
  body[448+:16]=2048;body[464+:16]=8192;body[480+:16]=16;body[496+:16]=1;
  @(negedge clk);#1;if(code!=0)$fatal(1,"AWB config rejected");submit=1;@(negedge clk);submit=0;boundary=1;@(negedge clk);boundary=0;
  awb_stats=1;@(negedge clk);awb_stats=0;if(ctrl.pending)$fatal(1,"insufficient neutral samples drove AWB");
  neutral_count=16;awb_stats=1;@(negedge clk);awb_stats=0;@(negedge clk);awb_stats=1;@(negedge clk);awb_stats=0;
  if(!ctrl.pending || gains[15:0]!=4112 || gains[63:48]!=4080 || gains[47:16]!=32'h10001000)$fatal(1,"bounded AWB gains differ");
  boundary=1;@(negedge clk);boundary=0;if(status[32+:32]!=4)$fatal(1,"AWB version did not bind source");
  $display("ISP_COLOUR_ENTITY_PASS queued frame, RGB12 non-diagonal matrix and row bound");$finish;
 end
 initial begin #10000;$fatal(1,"ISP_COLOUR_ENTITY_TIMEOUT");end
endmodule
