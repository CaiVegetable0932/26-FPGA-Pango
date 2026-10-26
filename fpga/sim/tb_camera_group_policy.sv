`timescale 1ns/1ps
// Policy-side mode2 checks complement the actual SCCB wire tests: source
// admission/version boundaries, AE settling and coordination with gamma/AWB.
module tb_camera_group_policy;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg submit=0,boundary=0,stats=0,done=0;reg [2:0] error=0;
 reg [383:0] body=0;reg [31:0] version=2;reg [47:0] sum=0;
 wire [7:0] code;wire [2303:0] status;wire pause_capture,apply,continuous,stable;
 wire [19:0] exposure;wire [9:0] gain;wire [31:0] cv;
 camera_brightness_control #(.DRAIN_TIMEOUT(1000)) dut(.clk(clk),.rst_n(rst_n),.submit_valid(submit),.body(body),.version(version),.entity_id(32'd5),
  .submit_code(code),.status(status),.source_quiesced(1'b0),.pause_capture(pause_capture),.apply_valid(apply),.continuous(continuous),.apply_ready(1'b1),
  .exposure(exposure),.gain(gain),.apply_done(done),.apply_error(error),.capture_boundary(boundary),.capture_epoch(64'd3),.capture_frame(64'd77),
  .statistics_valid(stats),.luminance_sum(sum),.samples(32'd100),.capture_camera_version(cv),.auto_stable(stable));
 task pulse_stats;
  begin @(negedge clk);stats=1;@(negedge clk);stats=0;end
 endtask
 task complete;
  begin repeat(4)@(negedge clk);done=1;@(negedge clk);done=0;end
 endtask
 task admit;
  begin @(negedge clk);boundary=1;@(negedge clk);boundary=0;end
 endtask
 initial begin
  #22;rst_n=1;
  body[7:0]=2;body[23:16]=96;body[31:24]=144;body[32+:32]=1000;body[64+:16]=16;
  body[80+:16]=16;body[96+:16]=32;body[112+:16]=1;body[128+:32]=16;body[160+:32]=17856;
  body[192+:32]=256;body[224+:16]=1;body[240+:16]=2;
  @(negedge clk);#1;if(code!=0)$fatal(1,"GROUP_POLICY rejected mode2");submit=1;@(negedge clk);submit=0;
  wait(apply);if(pause_capture || !continuous || stable || cv!=1)$fatal(1,"GROUP_POLICY drained continuous request or changed source early");
  complete();if(cv!=2 || status[32+:32]!=1)$fatal(1,"GROUP_POLICY missing pending admission version");
  admit();if(status[32+:32]!=2 || status[256+:8]!=2 || !status[114])$fatal(1,"GROUP_POLICY applied status/unverified flag");
  pulse_stats();pulse_stats();pulse_stats();
  if(apply || stable)$fatal(1,"GROUP_POLICY ignored hold or allowed racing gamma/AWB");
  pulse_stats();wait(apply);
  if(exposure!=1256 || pause_capture || stable)$fatal(1,"GROUP_POLICY AE step/drain gating");
  complete();admit();if(cv!=3)$fatal(1,"GROUP_POLICY automatic version");
  sum=12000;pulse_stats();pulse_stats();#1;if(!stable)$fatal(1,"GROUP_POLICY never released settled in-target loops");
  // Failure retains the last applied body and requires reset for an uncertain
  // sensor group; publishing the rejected body would relabel old sources.
  version=4;body[32+:32]=1500;@(negedge clk);submit=1;@(negedge clk);submit=0;wait(apply);error=1;complete();
  if(!pause_capture || stable || cv!=3 || status[120+:8]!=1)$fatal(1,"GROUP_POLICY failure last-good");
  body[7:0]=0;#1;if(code!=4)$fatal(1,"GROUP_POLICY allowed retry of uncertain partial group");
  $display("CAMERA_GROUP_POLICY_PASS live admission, AE hold/settle, loop exclusion, last-good/reset-required error");$finish;
 end
 initial begin #50000;$fatal(1,"GROUP_POLICY_TIMEOUT");end
endmodule
