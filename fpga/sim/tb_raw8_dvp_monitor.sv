`timescale 1ns/1ps
// Purpose: independent DVP widths/phases, coherent telemetry, and clock-stop
// behavior; does not substitute a synthetic source in the production design.
module tb_raw8_dvp_monitor;
 reg cc=0,mc=0,rst=0,run_cam=1,vs=1,href=0;
 always #6 if(run_cam)cc=~cc;
 always #4 mc=~mc;
 wire [95:0] geometry,progress;
 raw8_dvp_monitor #(.POLL_BITS(5)) dut(.cam_clk(cc),.cam_reset_n(rst),
  .mem_clk(mc),.mem_reset_n(rst),.vsync(vs),.href(href),
  .capture_state(8'ha5),.rejected(32'h11223344),.overflows(32'h55667788),
  .geometry(geometry),.progress(progress));
 task tick;begin @(negedge cc);end endtask
 task line(input integer w);integer i;begin
  href=1;for(i=0;i<w;i=i+1)tick();href=0;repeat(3)tick();
 end endtask
 reg [191:0] saved;integer y;
 initial begin
  repeat(5)tick();rst=1;repeat(5)tick();vs=0;repeat(5)tick();
  line(1920);line(1919);line(1921);
  vs=1;repeat(4)tick();line(12);vs=0;
  repeat(150)tick();
  if(geometry!=={8'd1,8'ha5,16'd1,16'd1921,16'd1919,16'd3,16'd2})
   $fatal(1,"RAW8_FAIL DVP geometry %h",geometry);
  if(progress[95:32]!==64'h5566778811223344 || progress[31:0]==0)
   $fatal(1,"RAW8_FAIL progress CDC %h",progress);
  // HREF fall and new VSYNC interval together must retain the old high line.
  vs=1;href=1;repeat(9)tick();href=0;vs=0;repeat(150)tick();
  if(geometry[79:16]!=={16'd1,16'd0,16'd0,16'd0})
   $fatal(1,"RAW8_FAIL coincident boundaries %h",geometry);
  // Drain the last ACK after stopping source; no fabricated progress follows.
  run_cam=0;repeat(100)@(negedge mc);saved={progress,geometry};
  repeat(200)@(negedge mc);
  if({progress,geometry}!==saved)$fatal(1,"RAW8_FAIL stopped clock telemetry changed");
  run_cam=1;repeat(150)tick();
  if(progress[31:0]==saved[127:96])$fatal(1,"RAW8_FAIL resumed clock stalled");
  $display("RAW8_DVP_MONITOR_PASS");$finish;
 end
 initial begin #1000000;$fatal(1,"RAW8_TIMEOUT DVP monitor");end
endmodule
