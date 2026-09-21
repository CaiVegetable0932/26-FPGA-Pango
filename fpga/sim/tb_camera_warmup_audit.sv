`timescale 1ns/1ps
// Purpose: exercise the real ten-frame startup gate (existing DVP test uses zero).
// Small geometry preserves state transitions; this is not measured camera timing.
module tb_camera_warmup_audit;
 reg clk=0,rst_n=0,vsync=0,href=0;
 always #5 clk=~clk;
 wire wr;
 integer f,y,x,writes=0;
 camera_data #(.FRAME_WIDTH(4),.FRAME_HEIGHT(2)) dut(.clk(clk),.rst_n(rst_n),
 .vsync(vsync),.href(href),.din(8'hA5),.cfg_done(1'b1),.ddr_init(1'b1),
 .pixel_data(),.wf_wr_en(wr),.sop(),.eop(),.vs(),.hs());
 task tick(input bit v,input bit h);
  begin @(negedge clk);vsync=v;href=h;@(posedge clk);#1;
   if(wr) writes=writes+1;
  end
 endtask
 task frame(input integer rows);
  begin
   repeat(5) tick(1,0);repeat(6) tick(0,0);
   for(y=0;y<rows;y=y+1) begin
    for(x=0;x<8;x=x+1) tick(0,1);
    repeat(3) tick(0,0);
   end
  end
 endtask
 initial begin
  repeat(4) tick(0,0);rst_n=1;repeat(5) tick(0,0);
  // Purpose: PCLK/VSYNC/HREF alone must not advance warmup on short frames.
  for(f=0;f<12;f=f+1) frame(1);
  if(writes!=0 || dut.eop_cnt!=0) $fatal(1,"WARMUP_FAIL: incomplete frames counted");
  for(f=0;f<10;f=f+1) frame(2);
  if(writes!=0 || dut.eop_cnt!=10) $fatal(1,"WARMUP_FAIL: first ten frames not discarded");
  frame(2);
  if(writes!=8) $fatal(1,"WARMUP_FAIL: eleventh frame not released");
  $display("WARMUP_PASS short_frames=12 discarded_complete=10 accepted_pixels=%0d",writes);
  $finish;
 end
 initial begin #100000;$fatal(1,"WARMUP_TIMEOUT");end
endmodule
