`timescale 1ns/1ps
// Independent integer ROI/luma/neutral oracle plus baseline cycle comparison.
// Exercise final selected pixels, stalls, held results, abort and cold reset.
module tb_statistics_area;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg frame_start=0,frame_abort=0,pixel_valid=0,pixel_ready=0,pixel_mask=0,pixel_last=0,result_ready=0;
 reg [191:0] frame_tag=0;reg [15:0] roi_x=0,roi_y=0,roi_width=17,roi_height=13,pixel_x=0,pixel_y=0;
 reg [23:0] pixel_rgb=0;wire result_failed,result_valid,rejected;wire [191:0] result_tag;
 wire [47:0] luminance_sum,red_sum,green_sum,blue_sum;wire [31:0] samples,dark,saturated,neutral_count;
 rgb_frame_statistics #(.SUPPORT_ABORT(1)) dut(.*);
 integer trial,seed=99173,random_value,r,g,b,y,hi,lo;
 integer e_sum,e_count,e_dark,e_sat,e_red,e_green,e_blue,e_neutral,checks=0;
 reg aborted;
 task check(input bit ok,input string label_text);
  begin checks++;if(!ok)$fatal(1,"STATISTICS_AREA %s frame=%0d",label_text,trial);end
 endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  for(trial=0;trial<160;trial++)begin
   @(negedge clk);frame_tag=trial+1;frame_start=1;
   roi_x=trial%3==0?0:1;roi_y=trial%3==0?0:2;roi_width=17-roi_x;roi_height=13-roi_y;
   @(negedge clk);frame_start=0;e_sum=0;e_count=0;e_dark=0;e_sat=0;e_red=0;e_green=0;e_blue=0;e_neutral=0;aborted=0;
   for(integer p=0;p<221;p++)begin
    @(negedge clk);pixel_x=p%17;pixel_y=p/17;
    pixel_rgb=$random(seed);random_value=$random(seed);pixel_mask=(random_value&7)!=0;
    pixel_valid=1;pixel_last=p==220;pixel_ready=0;
    repeat((random_value>>4)&3)@(negedge clk);pixel_ready=1;
    r=pixel_rgb[23:16];g=pixel_rgb[15:8];b=pixel_rgb[7:0];y=(77*r+150*g+29*b+128)/256;
    hi=r>g?r:g;if(b>hi)hi=b;lo=r<g?r:g;if(b<lo)lo=b;
    if(pixel_mask && pixel_x>=roi_x && pixel_y>=roi_y && pixel_x<roi_x+roi_width && pixel_y<roi_y+roi_height &&
       (pixel_x-roi_x)%4==0 && (pixel_y-roi_y)%4==0)begin
     e_sum+=y;e_count++;if(y<32)e_dark++;if(y>=250)e_sat++;
     if(lo>=32 && hi<240 && hi-lo<=hi/4)begin e_red+=r;e_green+=g;e_blue+=b;e_neutral++;end
    end
    @(negedge clk);pixel_valid=0;pixel_ready=0;
    if(trial%7==6 && p==100)begin
     frame_abort=1;@(negedge clk);frame_abort=0;aborted=1;p=221;
    end
   end
   #1;check(result_valid && result_tag==frame_tag && result_failed==aborted,"identity/completion");
   check(luminance_sum==e_sum && samples==e_count && dark==e_dark && saturated==e_sat,"ROI/luma totals");
   if(!aborted)check(red_sum==e_red && green_sum==e_green && blue_sum==e_blue && neutral_count==e_neutral,"neutral totals");
   repeat(4)@(negedge clk);check(result_valid,"held result");
   result_ready=1;@(negedge clk);result_ready=0;
   if(trial%19==18)begin rst_n=0;repeat(2)@(negedge clk);rst_n=1;end
  end
  $display("STATISTICS_AREA_PASS frames=%0d checks=%0d",trial,checks);$finish;
 end
 initial begin #10000000;$fatal(1,"STATISTICS_AREA_TIMEOUT");end
endmodule
