`timescale 1ns/1ps
// Purpose: file-based independent golden checks and identity/stall assertions.
module tb_lens_inverse_map;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,iv=0,ready=1;wire ir,ov,mask,ok;
 reg [447:0] coeff;
 reg signed [23:0] x,y;reg [63:0] itag;
 wire signed [27:0] u,v;wire [63:0] otag;
 reg [447:0] cf[0:7999];reg [23:0] xs[0:7999],ys[0:7999];
 reg [27:0] us[0:7999],vs[0:7999];integer masks[0:7999],oks[0:7999];
 integer fd,n=0,sent=0,received=0,rc,cycles=0,previous=-1,burst_count=0;
 string root;
 reg stalled=0;reg [122:0] hold_value;
 lens_inverse_map #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(ir),
  .in_x(x),.in_y(y),.in_ok(1'b1),.in_tag(itag),
  .k1(coeff[192+:32]),.k2(coeff[224+:32]),.p1(coeff[256+:32]),.p2(coeff[288+:32]),
  .fx(coeff[320+:32]),.fy(coeff[352+:32]),.cx(coeff[384+:32]),.cy(coeff[416+:32]),
  .width(16'd1920),.height(16'd1080),.out_valid(ov),.out_ready(ready),.out_u(u),.out_v(v),.out_mask(mask),.out_ok(ok),.out_tag(otag));
 always @(negedge clk) ready=received<400 ? 1 : $urandom_range(0,4)!=0;
 always @(posedge clk) if(rst_n) begin
  cycles=cycles+1;
  if(stalled && {ov,mask,ok,u,v,otag}!==hold_value) $fatal(1,"LENS_FAIL unstable stalled output");
  stalled=ov && !ready;hold_value={ov,mask,ok,u,v,otag};
  if(ov && ready) begin
   if(otag!==received || u!==us[received] || v!==vs[received] || mask!==masks[received][0] || ok!==oks[received][0])
    $fatal(1,"LENS_FAIL n=%0d tag=%0d u/v=%0d/%0d expected=%0d/%0d mask/ok=%b%b",received,otag,u,v,$signed(us[received]),$signed(vs[received]),mask,ok);
   if(received>0 && received<400) begin
    if(cycles-previous!=1) $fatal(1,"LENS_FAIL II not one");burst_count=burst_count+1;
   end
   previous=cycles;received=received+1;
  end
 end
 initial begin
  if(!$value$plusargs("VECTORS=%s",root)) $fatal(1,"LENS_FAIL missing vectors");
  fd=$fopen({root,"/lens.txt"},"r");if(!fd) $fatal(1,"LENS_FAIL open");
  while(!$feof(fd)) begin
   rc=$fscanf(fd,"%h %h %h %h %h %d %d\n",cf[n],xs[n],ys[n],us[n],vs[n],masks[n],oks[n]);
   if(rc==7) n=n+1;else if(!$feof(fd)) $fatal(1,"LENS_FAIL malformed vector");
  end
  $fclose(fd);repeat(4) @(negedge clk);rst_n=1;
  for(sent=0;sent<n;sent=sent+1) begin
   @(negedge clk);iv=1;coeff=cf[sent];x=xs[sent];y=ys[sent];itag=sent;
   do @(posedge clk);while(!ir);
  end
  @(negedge clk);iv=0;wait(received==n);@(negedge clk);
  $display("LENS_PASS pixels=%0d cycles=%0d burst_II=1 checked=%0d latency_stages=23",n,cycles,burst_count);$finish;
 end
 initial begin #2000000;$fatal(1,"LENS_TIMEOUT");end
endmodule

module tb_raw8_isp;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,start=0,abort_frame=0,iv=0,ready=1,sof=0,eol=0;
 wire frame_ready,ir,ov,os,oe,ol,mask,error,rejected;
 reg [15:0] width,height;reg [1:0] bayer;reg [31:0] black;reg [63:0] gains,tag;
 reg [7:0] raw;wire [23:0] rgb;wire [35:0] linear_rgb;wire [15:0] x,y;wire [63:0] out_tag;
 reg [7:0] raws[0:9999];reg [23:0] gold[0:9999];
 integer case_fd,fd,rc,case_index=0,sent=0,received=0,total=0,cycles=0,start_cycle;
 string root,filename;reg checking=0;
 raw8_isp #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(frame_ready),
  .frame_width(width),.frame_height(height),.frame_bayer(bayer),.black_levels(black),.colour_gains(gains),
  .frame_tag(tag),.frame_abort(abort_frame),.in_valid(iv),.in_ready(ir),.in_raw(raw),.in_sof(sof),.in_eol(eol),
  .out_valid(ov),.out_ready(ready),.out_rgb(rgb),.out_linear_rgb(linear_rgb),.out_x(x),.out_y(y),
  .out_sof(os),.out_eol(oe),.out_last(ol),.out_mask(mask),.out_tag(out_tag),.frame_error(error),.config_rejected(rejected));
 always @(negedge clk) ready=$urandom_range(0,4)!=0;
 always @(posedge clk) if(rst_n) begin
  cycles=cycles+1;
  if(checking && ov && ready) begin
   if(received>=total || rgb!==gold[received] || x!==received%width || y!==received/width ||
      os!==(received==0) || oe!==(received%width==width-1) || ol!==(received==total-1) || !mask || out_tag!==tag)
    $fatal(1,"ISP_FAIL case=%0d n=%0d xy=%0d/%0d rgb=%h expected=%h",case_index,received,x,y,rgb,gold[received]);
   received=received+1;
  end
 end
 initial begin
  if(!$value$plusargs("VECTORS=%s",root)) $fatal(1,"ISP_FAIL missing vectors");
  case_fd=$fopen({root,"/isp_cases.txt"},"r");if(!case_fd) $fatal(1,"ISP_FAIL open");
  repeat(4) @(negedge clk);rst_n=1;
  while(!$feof(case_fd)) begin
   rc=$fscanf(case_fd,"%d %d %d %h %h\n",width,height,bayer,black,gains);
   if(rc!=5) begin if(!$feof(case_fd)) $fatal(1,"ISP_FAIL malformed case");end
   else begin
    total=width*height;received=0;tag=64'hf012340000000000+case_index;
    filename=$sformatf("%s/isp_%0d.txt",root,case_index);fd=$fopen(filename,"r");
    if(!fd) $fatal(1,"ISP_FAIL missing frame");
    for(integer p=0;p<total;p=p+1) begin rc=$fscanf(fd,"%h %h\n",raws[p],gold[p]);if(rc!=2) $fatal(1,"ISP_FAIL truncated frame");end
    $fclose(fd);wait(frame_ready);@(negedge clk);start=1;checking=1;start_cycle=cycles;
    @(negedge clk);start=0;
    for(sent=0;sent<total;sent=sent+1) begin
     @(negedge clk);iv=1;raw=raws[sent];sof=sent==0;eol=sent%width==width-1;
     do @(posedge clk);while(!ir);
    end
    @(negedge clk);iv=0;wait(frame_ready);@(negedge clk);
    if(received!=total || error) $fatal(1,"ISP_FAIL incomplete frame count=%0d/%0d",received,total);
    $display("ISP_CASE_PASS index=%0d pixels=%0d cycles=%0d",case_index,total,cycles-start_cycle);
    checking=0;case_index=case_index+1;
   end
  end
  // A truncated frame abort must drain and reopen admission without reset.
  width=4;height=4;tag=42;@(negedge clk);start=1;@(negedge clk);start=0;
  @(negedge clk);iv=1;raw=55;sof=0;eol=0;do @(posedge clk);while(!ir);
  @(negedge clk);iv=0;abort_frame=1;@(negedge clk);abort_frame=0;
  wait(frame_ready);if(!error) $fatal(1,"ISP_FAIL abort not recorded");
  $display("ISP_PASS frames=%0d plus_abort",case_index);$finish;
 end
 initial begin #2000000;$fatal(1,"ISP_TIMEOUT");end
endmodule

module tb_rgb_enhance;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,start=0,finish=0,write_lut=0,commit=0,iv=0,ready=1;
 reg [7:0] addr,data,lut[0:255];reg [1:0] mode;
 wire frame_ready,rejected,ir,ov,mask;reg [95:0] samples;
 reg [31:0] requested_version=19;
 reg [11:0] a,b;reg im;reg [63:0] tag;wire [63:0] out_tag;wire [23:0] rgb;wire [31:0] active_version;
 reg [95:0] sample_list[0:1999];reg [11:0] aa[0:1999],bb[0:1999];reg [23:0] gold[0:1999];
 integer mm[0:1999],modes[0:1999];integer fd,rc,n=0,sent,received=0,m;string root;
 rgb_enhance #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(frame_ready),.frame_end(finish),
  .frame_mode(mode),.frame_lut_version(requested_version),.lut_write(write_lut),.lut_addr(addr),.lut_data(data),.lut_commit(commit),
  .lut_version(32'd19),.config_rejected(rejected),.in_valid(iv),.in_ready(ir),.in_samples(samples),.in_a(a),.in_b(b),.in_mask(im),.in_tag(tag),
  .out_valid(ov),.out_ready(ready),.out_rgb(rgb),.out_mask(mask),.out_tag(out_tag),.active_lut_version(active_version));
 always @(negedge clk) ready=received%600<200 ? 1 : $urandom_range(0,4)!=0;
 always @(posedge clk) if(rst_n && ov && ready) begin
  if(out_tag!==received || rgb!==gold[received] || mask!==mm[received][0])
   $fatal(1,"ENHANCE_FAIL n=%0d rgb=%h expected=%h tag=%0d mask=%b",received,rgb,gold[received],out_tag,mask);
  received=received+1;
 end
 initial begin
  if(!$value$plusargs("VECTORS=%s",root)) $fatal(1,"ENHANCE_FAIL missing vectors");
  $readmemh({root,"/gamma.hex"},lut);fd=$fopen({root,"/enhance.txt"},"r");if(!fd) $fatal(1,"ENHANCE_FAIL open");
  while(!$feof(fd)) begin rc=$fscanf(fd,"%d %h %h %h %d %h\n",modes[n],sample_list[n],aa[n],bb[n],mm[n],gold[n]);if(rc==6)n=n+1;end
  repeat(4) @(negedge clk);rst_n=1;
  // Incomplete LUT commit must be rejected.
  @(negedge clk);commit=1;@(negedge clk);commit=0;if(!rejected)$fatal(1,"ENHANCE_FAIL partial commit");
  for(integer i=0;i<256;i=i+1) begin @(negedge clk);write_lut=1;addr=i;data=lut[i];end
  @(negedge clk);write_lut=0;commit=1;@(negedge clk);commit=0;
  // The committed curve version must match the frame entity before admission.
  @(negedge clk);mode=1;requested_version=18;start=1;
  @(negedge clk);start=0;if(!rejected || !frame_ready)$fatal(1,"ENHANCE_FAIL wrong LUT version");requested_version=19;
  for(m=0;m<3;m=m+1) begin
   wait(frame_ready);@(negedge clk);mode=m;start=1;@(negedge clk);start=0;
   // Mid-frame writes/commit/start are rejected and cannot change the page.
   @(negedge clk);write_lut=1;addr=0;data=255;commit=1;
   @(negedge clk);write_lut=0;commit=0;if(!rejected)$fatal(1,"ENHANCE_FAIL midframe write");
   for(sent=m*600;sent<(m+1)*600;sent=sent+1) begin
    @(negedge clk);iv=1;samples=sample_list[sent];a=aa[sent];b=bb[sent];im=mm[sent][0];tag=sent;
    do @(posedge clk);while(!ir);
   end
   @(negedge clk);iv=0;wait(received==(m+1)*600);repeat(3)@(negedge clk);
   if(active_version!==(m==0 ? 0 : 19)) $fatal(1,"ENHANCE_FAIL version");
   finish=1;@(negedge clk);finish=0;wait(frame_ready);
  end
  $display("ENHANCE_PASS pixels=%0d modes=3 frame_locked",received);$finish;
 end
 initial begin #2000000;$fatal(1,"ENHANCE_TIMEOUT");end
endmodule
