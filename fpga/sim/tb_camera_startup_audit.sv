`timescale 1ns/1ps
// Purpose: audit the rewritten camera wrapper with production startup waits
// and an independent register-readback model; PCLK alone must not emit pixels.
module tb_camera_startup_audit;
 reg clk=0, pclk=0, reset_n=0;
 always #18.518518 clk=~clk;
 always #10.416667 pclk=~pclk;
 tri1 scl,sda;
 wire sensor_reset_n,pwdn,configured,wr;
 wire [15:0] pixels;
 integer starts,reads,writes;
 wire [7:0] run_reg;
 integer cycles=0,release_cycle=0,first_start_cycle=0;
 reg released=0;
 camera dut(.clk(clk),.rst_n(reset_n),.SCL(scl),.SDA(sda),
 .camera_clk(pclk),.camera_data(8'd0),.camera_herf(1'b0),
 .camera_vsync(1'b0),.ddr_init(1'b1),.camera_rstn(sensor_reset_n),
 .camera_pwnd(pwdn),.init_done(configured),.wf_wr_data(pixels),
 .wf_wr_en(wr),.vs(),.hs(),.sop(),.eop());
 ov5640_register_model slave(sensor_reset_n,scl,sda,0,writes,reads,starts,run_reg);
 // Purpose: time RESETB release and first serial transaction in 27 MHz cycles.
 always @(posedge clk) if(reset_n) begin
  cycles=cycles+1;
  if(sensor_reset_n && !released) begin released=1;release_cycle=cycles;end
  if(starts>0 && first_start_cycle==0) begin
   first_start_cycle=cycles;
   if(!released || cycles-release_cycle<540000)
    $fatal(1,"STARTUP_FAIL: SCCB earlier than 20ms after RESETB");
  end
 end
 // Purpose: PCLK alone must not be mistaken for valid data before real frames.
 always @(posedge pclk) if(reset_n && wr===1'b1)
  $fatal(1,"STARTUP_FAIL: no HREF/VSYNC but pixels escaped startup gate");
 initial begin
  #100; reset_n=1;
  wait(configured===1'b1); #1000;
  if(writes!=247 || reads!=16 || run_reg!=8'h02 || pwdn!=0)
   $fatal(1,"STARTUP_FAIL: verified configuration count/state");
  $display("STARTUP_PASS cycles=%0d reset_release=%0d first_sccb=%0d writes=%0d time_ps=%0t",cycles,release_cycle,first_start_cycle,writes,$time);
  $finish;
 end
 initial begin #600000000; $fatal(1,"STARTUP_TIMEOUT"); end
endmodule
