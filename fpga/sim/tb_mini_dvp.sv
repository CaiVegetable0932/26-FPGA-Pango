`timescale 1ns/1ps
// Purpose: exercise DVP RGB565 byte order, line-gap re-alignment, frame reset
// and readiness gating. This is not a DDR/frame-integrity or physical-I/O test.
module tb_mini_dvp;
 reg clk=0, rst_n=0, vsync=0, href=0, cfg_done=0, ddr_init=0;
 reg [7:0] din=0;
 wire [15:0] pixel_data; wire wf_wr_en,sop,eop,vs,hs;
 integer checks=0;
 always #5 clk=~clk;
 camera_data #(.FRAME_WIDTH(4),.FRAME_HEIGHT(2),.WARMUP_FRAMES(0)) dut(
 .clk(clk),.rst_n(rst_n),.vsync(vsync),.href(href),.din(din),
 .cfg_done(cfg_done),.ddr_init(ddr_init),.pixel_data(pixel_data),
 .wf_wr_en(wf_wr_en),.sop(sop),.eop(eop),.vs(vs),.hs(hs));
 // Purpose: drive only on the falling edge and inspect settled registered outputs.
 task tick(input reg v,input reg h,input reg [7:0] d);
 begin @(negedge clk);vsync=v;href=h;din=d;@(posedge clk);#2;end endtask
 task check(input reg ok,input [255:0] label_text);
 begin checks=checks+1;if(ok!==1'b1)begin $display("MINI_DVP_FAIL %s",label_text);$fatal(1);end end endtask
 task new_frame;
 begin repeat(5)tick(1,0,0);repeat(6)tick(0,0,0);end endtask
 task pixel(input reg [15:0] value);
 begin tick(0,1,value[15:8]);check(!wf_wr_en,"first byte not a pixel");
 tick(0,1,value[7:0]);check(wf_wr_en && pixel_data===value,"RGB565 high/low order");end endtask
 initial begin
  repeat(4)tick(0,0,0);rst_n=1;new_frame;
  tick(0,1,8'hAA);tick(0,1,8'hBB);check(!wf_wr_en,"configuration gate");
  cfg_done=1;ddr_init=1;repeat(5)tick(0,0,0);new_frame;
  pixel(16'hF800);check(sop,"first pixel SOP");
  pixel(16'h07E0);pixel(16'h001F);pixel(16'hFFFF);tick(0,0,0);
  pixel(16'h1234);pixel(16'h5678);pixel(16'h9ABC);pixel(16'hDEF0);
  check(eop,"expected final pixel EOP");tick(0,0,0);
  // Purpose: an odd/short row aborts the remaining frame, not just its dangling byte.
  new_frame;tick(0,1,8'hAA);check(!wf_wr_en,"dangling first byte");
  tick(0,0,0);tick(0,1,8'h13);tick(0,1,8'h57);
  check(!wf_wr_en,"short row aborts until next frame");
  // Purpose: VSYNC must discard partial line and row counters.
  new_frame;pixel(16'h2468);check(sop,"new frame re-aligned SOP");
  // Purpose: DDR-ready deassertion stops FIFO writes after the 2FF pipeline.
  ddr_init=0;repeat(5)tick(0,0,0);tick(0,1,8'hAA);tick(0,1,8'hBB);
  check(!wf_wr_en,"DDR readiness gate");
  rst_n=0;tick(0,0,0);check(!wf_wr_en && !sop && !eop,"reset idle");
  $display("MINI_DVP_PASS checks=%0d",checks);$finish;
 end
 initial begin #100000;$display("MINI_DVP_TIMEOUT");$fatal(1);end
endmodule
