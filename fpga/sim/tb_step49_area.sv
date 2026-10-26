`timescale 1ns/1ps
// Full-input signed64 oracle, legal terminal coordinate 65536, rejected regions,
// stalls and live coefficient changes verify the exact signed49 state bound.
module tb_step49_area;
 reg clk=0,rst_n=0,start_valid=0,out_ready=0;always #3.333 clk=~clk;
 reg [15:0] start_u=0,start_v=0,region_width=1,region_height=1;
 reg signed [31:0] a00=0,a01=0,a02=0,a10=0,a11=0,a12=0;
 reg [159:0] region_tag=0;wire start_ready,out_valid,out_ok,out_last,rejected;
 wire signed [23:0] out_x,out_y;wire signed [39:0] out_q0,out_q1;
 wire [15:0] out_u,out_v;wire [159:0] out_tag;
 affine_ray_stepper dut(.*);
 reg signed [31:0] aa,ab,ac,ba,bb,bc;reg [15:0] su,sv,rw,rh;
 reg signed [63:0] gx,gy,qx,qy;reg good,legal_region;
 integer trial,received=0,total=0,seed=715003,checks=0;
 always @(negedge clk)out_ready=($random(seed)&7)!=0;
 always @(posedge clk)if(rst_n && out_valid && out_ready)begin
  gx=$signed(aa)*$signed({1'b0,out_u})+$signed(ab)*$signed({1'b0,out_v})+$signed(ac);
  gy=$signed(ba)*$signed({1'b0,out_u})+$signed(bb)*$signed({1'b0,out_v})+$signed(bc);
  qx=(gx+64'sd32)>>>6;qy=(gy+64'sd32)>>>6;
  good=gx>=-64'sd549755813888 && gx<64'sd549755813888 && gy>=-64'sd549755813888 && gy<64'sd549755813888 &&
       qx>=-64'sd8388608 && qx<64'sd8388608 && qy>=-64'sd8388608 && qy<64'sd8388608;
  if(!legal_region || out_x!==qx[23:0] || out_y!==qy[23:0] || out_q0!==gx[39:0] || out_q1!==gy[39:0] || out_ok!==good ||
     out_u!==16'(su+received%rw) || out_v!==16'(sv+received/rw) || out_last!==(received==rw*rh-1) || out_tag!==160'(trial+1))
   $fatal(1,"STEP49_ORACLE trial=%0d pixel=%0d",trial,received);
  received++;checks++;
 end
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  for(trial=0;trial<1000;trial++)begin
   wait(start_ready);@(negedge clk);
   start_u=trial%3==0?65535-trial%8:trial%3==1?0:$random(seed);
   start_v=trial%3==0?65535-trial%8:trial%3==1?0:$random(seed);
   region_width=1+trial%9;region_height=1+(trial/9)%9;
   a00=$random(seed);a01=$random(seed);a02=$random(seed);a10=$random(seed);a11=$random(seed);a12=$random(seed);
   if(trial%17==0)begin a00='h80000000;a01='h80000000;a02='h80000000;a10='h7fffffff;a11='h7fffffff;a12='h7fffffff;end
   if(trial%17==1)begin a00=32'd64;a01=0;a02=-32'sd32;a10=0;a11=32'd64;a12=-32'sd32;end
   su=start_u;sv=start_v;rw=region_width;rh=region_height;aa=a00;ab=a01;ac=a02;ba=a10;bb=a11;bc=a12;
   legal_region={1'b0,su}+{1'b0,rw}<=65536 && {1'b0,sv}+{1'b0,rh}<=65536;
   received=0;region_tag=trial+1;start_valid=1;
   @(negedge clk);start_valid=0;
   // Subsequent public input changes must not alter this accepted region.
   a00=~a00;a01=~a01;a02=~a02;a10=~a10;a11=~a11;a12=~a12;region_tag=0;
   // Sample after registered updates settle: preparing->active can produce a
   // delta-cycle ready glitch, which is not an accepted clock-edge handshake.
   do @(negedge clk);while(!start_ready);
   if(received!=(legal_region?rw*rh:0))$fatal(1,"STEP49 count trial=%0d got=%0d",trial,received);
   total+=received;
   if(trial%37==36)begin rst_n=0;repeat(2)@(negedge clk);rst_n=1;end
  end
  $display("STEP49_AREA_PASS regions=%0d pixels=%0d checks=%0d",trial,total,checks);$finish;
 end
 initial begin #10000000;$fatal(1,"STEP49_TIMEOUT");end
endmodule
