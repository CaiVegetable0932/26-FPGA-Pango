`timescale 1ns/1ps
// Independent full-precision pixel oracles plus stalls/warm-reset coverage for
// separating unreset datapath registers from asynchronous validity controls.
module tb_image_payload_area;
 reg clk=0,rst_n=0;always #3.333 clk=~clk;
 reg iv=0,ready=1,im=0;reg [95:0] samples=0;reg [11:0] a=0,b=0;
 reg [63:0] tag=0;reg [35:0] linear_rgb=0;reg [161:0] coefficients=0;
 wire bi,bv,bm,ci,cv,cm,ei,ev,em;wire [23:0] brgb,crgb,ergb;
 wire [63:0] bt,ct,et;wire frame_ready;reg start=0,finish=0,write_lut=0,commit=0;
 reg [7:0] addr=0,data=0;reg [1:0] mode=0;
 rgb_bilinear #(.TAG_BITS(64)) bilinear(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(bi),
  .in_samples(samples),.in_a(a),.in_b(b),.in_mask(im),.in_tag(tag),
  .out_valid(bv),.out_ready(ready),.out_rgb(brgb),.out_mask(bm),.out_tag(bt));
 rgb_colour_matrix #(.TAG_BITS(64)) colour(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(ci),
  .in_rgb(linear_rgb),.coefficients(coefficients),.in_tag(tag),.in_mask(im),
  .out_valid(cv),.out_ready(ready),.out_rgb(crgb),.out_mask(cm),.out_tag(ct));
 rgb_enhance #(.TAG_BITS(64)) enhance(.clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(frame_ready),
  .frame_end(finish),.frame_mode(mode),.frame_lut_version(32'd7),.lut_write(write_lut),.lut_addr(addr),.lut_data(data),
  .lut_commit(commit),.lut_version(32'd7),.lut_page(1'b0),.in_valid(iv),.in_ready(ei),
  .in_samples(samples),.in_a(a),.in_b(b),.in_mask(im),.in_tag(tag),
  .out_valid(ev),.out_ready(ready),.out_rgb(ergb),.out_mask(em),.out_tag(et));
 reg [23:0] expected_b[0:20000],expected_c[0:20000],expected_e[0:20000];
 reg expected_mask[0:20000];integer checked_b=0,checked_c=0,checked_e=0;
 integer seed=725191,n,phase,lane;reg [95:0] transformed;
 // Perform a single 64-bit weighted sum and final rounding, independent of
 // the implementation's horizontal/vertical staged partial products.
 function automatic [23:0] bilinear_oracle(input [95:0] s,input [11:0] x,y,input mask);
  reg [63:0] value;integer c;
  begin
   bilinear_oracle=0;
   for(c=0;c<3;c++)begin
    value=64'(s[c*8+:8])*(4096-x)*(4096-y)+64'(s[24+c*8+:8])*x*(4096-y)+
          64'(s[48+c*8+:8])*(4096-x)*y+64'(s[72+c*8+:8])*x*y+8388608;
    bilinear_oracle[c*8+:8]=mask ? value>>24 : 0;
   end
  end
 endfunction
 function automatic [23:0] colour_oracle(input [35:0] rgb,input [161:0] co,input mask);
  reg signed [63:0] sum,q;integer row,col;
  begin
   colour_oracle=0;
   for(row=0;row<3;row++)begin
    sum=0;
    for(col=0;col<3;col++)sum=sum+$signed(co[(row*3+col)*18+:18])*$signed({1'b0,rgb[(2-col)*12+:12]});
    q=(sum+131072)>>>18;
    colour_oracle[(2-row)*8+:8]=!mask || q<0 ? 0 : q>255 ? 255 : q[7:0];
   end
  end
 endfunction
 always @(posedge clk)if(rst_n)begin
  if(iv)begin
   expected_mask[tag]=im;
   if(bi)expected_b[tag]=bilinear_oracle(samples,a,b,im);
   if(ci)expected_c[tag]=colour_oracle(linear_rgb,coefficients,im);
   if(ei)begin
    transformed=samples;
    if(mode==1)for(integer k=0;k<12;k++)transformed[k*8+:8]=255-samples[k*8+:8];
    expected_e[tag]=bilinear_oracle(transformed,a,b,im);
   end
  end
  if(bv && ready)begin
   if(brgb!==expected_b[bt] || bm!==expected_mask[bt])$fatal(1,"BILINEAR_ORACLE tag=%0d",bt);
   checked_b++;
  end
  if(cv && ready)begin
   if(crgb!==expected_c[ct] || cm!==expected_mask[ct])$fatal(1,"COLOUR_ORACLE tag=%0d got=%h expected=%h",ct,crgb,expected_c[ct]);
   checked_c++;
  end
  if(ev && ready)begin
   if(ergb!==expected_e[et] || em!==expected_mask[et])$fatal(1,"ENHANCE_ORACLE tag=%0d",et);
   checked_e++;
  end
 end
 initial begin
  // Each phase cold-programs a complete curve, then resets a nonempty stalled
  // pipeline. Public validity must flush while originally unreset data holds.
  for(phase=0;phase<4;phase++)begin
   rst_n=0;iv=0;start=0;ready=0;repeat(3)@(negedge clk);rst_n=1;ready=1;
   for(n=0;n<256;n++)begin @(negedge clk);write_lut=1;addr=n;data=255-n;end
   @(negedge clk);write_lut=0;commit=1;@(negedge clk);commit=0;
   mode=phase%2;start=1;@(negedge clk);start=0;
   for(n=0;n<4000;n++)begin
    @(negedge clk);tag=phase*4000+n;iv=($random(seed)&7)!=0;ready=($random(seed)&3)!=0;im=$random(seed);
    samples={$random(seed),$random(seed),$random(seed)};a=$random(seed);b=$random(seed);
    linear_rgb={$random(seed),$random(seed)};
    for(lane=0;lane<9;lane++)coefficients[lane*18+:18]=$random(seed);
    if(n%17==0)begin a=0;b=4095;samples='1;end
   end
   // Keep traffic live through a stalled warm reset; all oracle queues use
   // distinct tags for the next phase so stale data cannot silently match.
   @(negedge clk);ready=0;
  end
  rst_n=0;iv=0;repeat(3)@(negedge clk);rst_n=1;ready=1;repeat(40)@(negedge clk);
  if(checked_b<5000 || checked_c<5000 || checked_e<5000)$fatal(1,"Insufficient image coverage");
  $display("IMAGE_PAYLOAD_PASS bilinear=%0d colour=%0d enhance=%0d warm_resets=4",checked_b,checked_c,checked_e);$finish;
 end
 initial begin #2000000;$fatal(1,"IMAGE_PAYLOAD_TIMEOUT");end
endmodule
