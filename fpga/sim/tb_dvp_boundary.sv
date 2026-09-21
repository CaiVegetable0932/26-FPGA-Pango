`timescale 1ns/1ps
// Purpose: cover first-byte/VSYNC and last-HREF/VSYNC coincident boundaries.
// All DVP pins are source-synchronous; no invented blanking interval is required.
module tb_dvp_boundary #(parameter WIDTH=4, HEIGHT=2);
 reg clk=0,rst_n=0,vsync=0,href=0;
 reg [7:0] data=0;
 wire wr,eop;wire [15:0] pixel;wire [3:0] seen;
 integer gap,row,b,n=0,ends=0;
 always #5 clk=~clk;
 camera_data #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.WARMUP_FRAMES(0)) dut(
 .clk(clk),.rst_n(rst_n),.vsync(vsync),.href(href),.din(data),
 .cfg_done(1'b1),.ddr_init(1'b1),.pixel_data(pixel),.wf_wr_en(wr),
 .sop(),.eop(eop),.vs(),.hs());
 mini_dvp_observe #(.WIDTH_BYTES(WIDTH*2),.HEIGHT(HEIGHT)) observer(clk,rst_n,vsync,href,seen);
 task tick(input bit v,input bit h,input [7:0] d);
  begin @(negedge clk);vsync=v;href=h;data=d;@(posedge clk);#1;
   if(wr) begin
    if(pixel!=={8'(2*n),8'(2*n+1)}) $fatal(1,"BOUNDARY_FAIL shifted pixels");
    n=n+1;
   end
   if(eop) ends=ends+1;
  end
 endtask
 initial begin
  for(gap=0;gap<=6;gap=gap+1) begin
   rst_n=0;repeat(4)tick(1,0,0);n=0;ends=0;
   rst_n=1;repeat(6)tick(1,0,0);repeat(gap)tick(0,0,0);
   for(row=0;row<HEIGHT;row=row+1) begin
    for(b=0;b<WIDTH*2;b=b+1) tick(0,1,row*WIDTH*2+b);
    if(row<HEIGHT-1)repeat(3)tick(0,0,0);
   end
   // Purpose: the final HREF fall is allowed on the same edge as VSYNC rise.
   tick(1,0,0);repeat(3)tick(1,0,0);
   $display("BOUNDARY_COUNTS gap=%0d pixels=%0d eop=%0d flags=%b",gap,n,ends,seen);
   if(n!=WIDTH*HEIGHT || ends!=1 || seen!=15) $fatal(1,"BOUNDARY_FAIL incomplete frame");
  end
  $display("DVP_BOUNDARY_PASS");$finish;
 end
 initial begin #1000000000;$fatal(1,"BOUNDARY_TIMEOUT");end
endmodule
