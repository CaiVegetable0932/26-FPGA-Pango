`timescale 1ns/1ps
// Purpose: exercise nonconstant positive projective depth and joint stalls.
// An independent exact integer divide bounds both normalized rays to 2 LSBs;
// a behind-camera region must retain tags but mark every result invalid.
module tb_projective_ray_stepper;
 reg clk=0,rst=0,start=0,ready=1;always #3.3 clk=~clk;
 wire start_ready,valid,ok,last,rejected;wire signed [23:0] x,y;wire [15:0] u,v;
 reg signed [31:0] z_offset=32'sd67108864;
 integer cycle=0,count=0,frame=0;reg [31:0] held;reg was_stalled=0;
 projective_ray_stepper dut(.clk(clk),.rst_n(rst),.start_valid(start),.start_ready(start_ready),
  .start_u(16'd0),.start_v(16'd0),.region_width(16'd32),.region_height(16'd8),
  .a00(32'sd1048576),.a01(32'sd0),.a02(-32'sd33554432),
  .a10(32'sd0),.a11(32'sd1048576),.a12(-32'sd16777216),
  .a20(32'sd524288),.a21(32'sd0),.a22(z_offset),
  .out_valid(valid),.out_ready(ready),.out_x(x),.out_y(y),.out_u(u),.out_v(v),.out_ok(ok),.out_last(last),.rejected(rejected));
 reg signed [63:0] n0,n1,z,ex,ey,dx,dy;
 always @(negedge clk)if(rst)ready=(cycle%7)!=3 && (cycle%7)!=4;
 always @(posedge clk)if(rst)begin
  cycle=cycle+1;
  if(valid && !ready)begin
   if(was_stalled && held!={u,v})$fatal(1,"Projection changed stalled tag");
   held={u,v};was_stalled=1;
  end else was_stalled=0;
  if(valid && ready)begin
   if(u!=count%32 || v!=count/32 || last!=(count==255) || rejected)$fatal(1,"Projection order/last");
   if(frame==0)begin
    n0=1048576*u-33554432;n1=1048576*v-16777216;z=524288*u+67108864;
    // Match the defined positive-half rounding for both signs, using floor
    // rather than truncation towards zero on the negative exact quotient.
    ex=((n0<<20)+z/2)/z;ey=((n1<<20)+z/2)/z;
    if(((n0<<20)+z/2)<0 && (((n0<<20)+z/2)%z)!=0)ex=ex-1;
    if(((n1<<20)+z/2)<0 && (((n1<<20)+z/2)%z)!=0)ey=ey-1;
    dx=$signed(x)-ex;dy=$signed(y)-ey;
    if(!ok || dx>2 || dx< -2 || dy>2 || dy< -2)$fatal(1,"Projection numeric x/y=%0d/%0d expected=%0d/%0d",x,y,ex,ey);
   end else if(ok)$fatal(1,"Negative depth accepted");
   count=count+1;
  end
 end
 initial begin
  #100;rst=1;wait(start_ready);@(negedge clk);start=1;@(negedge clk);start=0;wait(count==256);wait(start_ready);
  @(negedge clk);frame=1;count=0;z_offset=-67108864;start=1;@(negedge clk);start=0;wait(count==256);wait(start_ready);
  $display("TB_PROJECTIVE_RAY_STEPPER_PASS pixels=512");$finish;
 end
 initial begin #1000000;$fatal(1,"Projective timeout");end
endmodule
