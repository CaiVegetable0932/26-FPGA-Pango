`timescale 1ns/1ps
// Compare serialized residual arithmetic to an independent absolute trajectory
// and causal smoothing scoreboard, including signed round-off and saturation.
module tb_motion_trajectory;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,clear=0,valid=0,domain=1;
 reg [63:0] fid=0;reg [255:0] cfg=0;reg signed [31:0] dx=0,dy=0,rotation=0,scale=0;
 wire result;wire [63:0] result_frame;wire [191:0] matrix;wire [3:0] status;wire [31:0] zoom;
 motion_trajectory dut(.clk(clk),.rst_n(rst_n),.clear(clear),.observation_valid(valid),.enabled(1'b1),.domain_valid(domain),
  .epoch(64'd9),.frame_id(fid),.observation_status(4'd0),.config_entity(cfg),.dx_q16(dx),.dy_q16(dy),
  .rotation_q26(rotation),.scale_delta_q26(scale),.inv_focal_q26(32'sd2097152),.result_valid(result),
  .result_epoch(),.result_frame(result_frame),.compensation(matrix),.status(status),.requested_zoom_q16(zoom));
 longint signed path[0:3],smooth[0:3],correction[0:3],d[0:3],limit[0:3],expected[0:5],expected_zoom,ax,ay,ar,az;
 integer n,i;
 task observe;begin @(negedge clk);fid=fid+1;valid=1;@(negedge clk);valid=0;wait(result);#1;end endtask
 initial begin
  cfg[15:8]=3;cfg[95:64]=262144;cfg[127:96]=100000;cfg[159:128]=100000;
  for(i=0;i<4;i=i+1)begin path[i]=0;smooth[i]=0;limit[i]=i<2?262144:100000;end
  #21;rst_n=1;observe;if(status!=1)$fatal(1,"first sample needs reference");
  for(n=0;n<24;n=n+1)begin
   dx=(n%3==0?-1:1)*(65536+n*971);dy=(n%2==0?-1:1)*(32768+n*499);
   rotation=(n%2==0?-1:1)*(4000+n*97);scale=(n%3==0?-1:1)*(2000+n*53);
   d[0]=dx;d[1]=dy;d[2]=rotation;d[3]=scale;
   for(i=0;i<4;i=i+1)begin path[i]=path[i]+d[i];smooth[i]=smooth[i]+((path[i]-smooth[i])>>>3);
    correction[i]=path[i]-smooth[i];if(correction[i]>limit[i])correction[i]=limit[i];if(correction[i]<-limit[i])correction[i]=-limit[i];end
   expected[0]=67108864+correction[3];expected[1]=-correction[2];expected[2]=(correction[0]*2097152+32768)>>>16;
   expected[3]=correction[2];expected[4]=expected[0];expected[5]=(correction[1]*2097152+32768)>>>16;
   ax=correction[0]<0?-correction[0]:correction[0];ay=correction[1]<0?-correction[1]:correction[1];
   ar=correction[2]<0?-correction[2]:correction[2];az=correction[3]<0?-correction[3]:correction[3];
   expected_zoom=65536+(ax+479)/480+(ay+269)/270+(ar>>8)+(az>>9);if(expected_zoom>131072)expected_zoom=131072;
   observe;
   if(status!=0 || result_frame!=fid)$fatal(1,"source/status mismatch");
   for(i=0;i<6;i=i+1)if($signed(matrix[i*32+:32])!=expected[i])$fatal(1,"trajectory mismatch frame=%d component=%d actual=%d expected=%d",fid,i,$signed(matrix[i*32+:32]),expected[i]);
   if(zoom<expected_zoom || zoom>expected_zoom+2)$fatal(1,"unsigned reciprocal not conservative/bounded");
  end
  @(negedge clk);clear=1;@(negedge clk);clear=0;observe;if(status!=1)$fatal(1,"clear did not reset trajectory");
  domain=0;observe;if(status!=4)$fatal(1,"invalid coordinate domain admitted");
  $display("PASS serialized trajectory signed exactness/clipping/reciprocal-bound/source/clear");$finish;
 end
 initial begin #100000;$fatal(1,"trajectory timeout");end
endmodule
