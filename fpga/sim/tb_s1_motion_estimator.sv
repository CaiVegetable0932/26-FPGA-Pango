`timescale 1ns/1ps
// Deterministic asymmetric texture tests the real passive S1 sampler and SAD
// datapath, including a known three-region similarity displacement and flatness.
module tb_s1_motion_estimator;
 localparam D=30;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,clear=0,start=0,pixel=0,complete=0;
 reg [15:0] x=0,y=0;reg [23:0] rgb=0;reg [63:0] id=0;reg [255:0] cfg=0;
 wire valid;wire [3:0] status;wire signed [31:0] dx,dy,rot,scale;wire [63:0] rid;
 s1_motion_estimator #(.WIDTH(64*D),.HEIGHT(36*D),.TW(64),.TH(36)) dut(.clk(clk),.rst_n(rst_n),.clear(clear),
  .frame_start(start),.epoch(64'd3),.frame_id(id),.colour_version(32'd1),.camera_version(32'd1),.config_entity(cfg),
  .pixel_valid(pixel),.x(x),.y(y),.rgb(rgb),.pixel_mask(1'b1),.frame_complete(complete),.frame_legal(1'b1),
  .result_valid(valid),.result_epoch(),.result_frame(rid),.translation_x_q16(dx),.translation_y_q16(dy),
  .rotation_q26(rot),.scale_delta_q26(scale),.confidence(),.status(status),.dropped(),.cycles());
 function [7:0] texture(input integer u,v);integer t;begin t=(u*1664525+v*1013904223)^((u*v+19)*69069);texture=(t>>8)^t;end endfunction
 task frame(input integer mode);integer u,v,offset;reg [7:0] l;begin
  @(negedge clk);id=id+1;start=1;@(negedge clk);start=0;
  for(v=0;v<36*D;v=v+1)for(u=0;u<64*D;u=u+1)begin
   @(negedge clk);pixel=1;x=u;y=v;
   offset=u/D<24?-1:u/D<40?0:1;
   l=mode==0?texture(u/D,v/D):mode==1?texture(u/D-1,v/D+1):mode==2?8'd80:texture(u/D-offset,v/D-offset);
   rgb={l,l,l};
  end
  @(negedge clk);pixel=0;complete=1;@(negedge clk);complete=0;
  wait(valid);#1;if(rid!=id)$fatal(1,"source identity mismatch");
 end endtask
 integer z;
 initial begin
  cfg[0]=1;cfg[15:8]=3;cfg[23:16]=2;cfg[47:32]=20;cfg[63:48]=20;cfg[223:192]=2000;
  #21;rst_n=1;frame(0);for(z=0;z<2304;z=z+1)if(dut.page1[z]!=texture(z%64,z/64)) $fatal(1,"lowpass z%0d got%0d want%0d col%0d",z,dut.page1[z],texture(z%64,z/64),dut.column_sum[z%64]);if(status!=1)$fatal(1,"first observation must degrade");
  frame(1);if(status!=0 || dx!=D*65536 || dy!= -D*65536 || rot!=0 || scale!=0)$fatal(1,"translation status=%d dx=%d dy=%d r=%d s=%d",status,dx,dy,rot,scale);
  @(negedge clk);clear=1;@(negedge clk);clear=0;
  frame(0);frame(3);if(status!=0 || dx!=0 || dy!=0 || rot!=4194304 || scale!=4194304)$fatal(1,"similarity status=%d dx=%d dy=%d r=%d s=%d",status,dx,dy,rot,scale);
  frame(2);if(status!=3)$fatal(1,"low texture must degrade");
  $display("PASS S1 three-region translation/rotation/scale + low-texture degradation");$finish;
 end
 initial begin #1000000000;$fatal(1,"timeout");end
endmodule
