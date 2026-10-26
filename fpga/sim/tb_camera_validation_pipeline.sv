`timescale 1ns/1ps
// Compare exact arithmetic, legal/reject codes and atomic queue publication
// against the immediate legacy consumer in both manual-only and AUTO builds.
module camera_validation_case #(parameter AUTO=1)(output reg done=0);
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,submit=0;reg [383:0] body=0,saved;
 reg [31:0] version=2,id=5;
 wire [7:0] expected,actual;wire [2303:0] old_status,new_status;
 camera_brightness_control #(.SUPPORT_AUTO(AUTO)) legacy(.clk(clk),.rst_n(rst_n),.submit_valid(submit),
  .body(body),.version(version),.entity_id(id),.submit_code(expected),.status(old_status),
  .source_quiesced(1'b0),.apply_ready(1'b1),.apply_done(1'b0),.apply_error(3'd0),
  .capture_boundary(1'b0),.capture_epoch(64'd0),.capture_frame(64'd0),.statistics_valid(1'b0),.luminance_sum(48'd0),.samples(32'd0));
 camera_brightness_control #(.SUPPORT_AUTO(AUTO),.PIPELINED_VALIDATION(1)) dut(.clk(clk),.rst_n(rst_n),.submit_valid(submit),
  .body(body),.version(version),.entity_id(id),.submit_code(actual),.status(new_status),
  .source_quiesced(1'b0),.apply_ready(1'b1),.apply_done(1'b0),.apply_error(3'd0),
  .capture_boundary(1'b0),.capture_epoch(64'd0),.capture_frame(64'd0),.statistics_valid(1'b0),.luminance_sum(48'd0),.samples(32'd0));
 integer trial,i,cycles,checks=0,seed=32'h7132abcd;
 reg [31:0] random_value;reg [63:0] oracle_product,oracle_tolerance;
 // Arithmetic checks cover all truncated operands, even when the full raw
 // range validator rejects them. This detects reassociation/carry mistakes.
 always @(negedge clk)if(rst_n && dut.sequential_validation.busy)begin
  oracle_tolerance=64'(dut.sequential_validation.frozen_line[19:0])*150;
  oracle_product=64'(dut.sequential_validation.frozen_period[14:0])*oracle_tolerance;
  if(dut.sequential_validation.phase>=3 && dut.sequential_validation.tolerance!==oracle_tolerance[27:0])
   $fatal(1,"camera tolerance mismatch AUTO=%0d",AUTO);
  if(dut.sequential_validation.phase==6 && dut.sequential_validation.product!==oracle_product[42:0])
   $fatal(1,"camera partial product mismatch AUTO=%0d",AUTO);
  if(dut.sequential_validation.phase==7 && dut.sequential_validation.residual!==44'(oracle_product-64'd16000000000))
   $fatal(1,"camera residual mismatch AUTO=%0d",AUTO);
 end
 task valid_body(input [31:0] period,input [31:0] line_time);
  begin
   body=0;body[15:8]=1;body[23:16]=96;body[31:24]=144;
   body[32+:32]=period;body[64+:16]=16;body[80+:16]=16;body[96+:16]=32;body[112+:16]=1;
   body[128+:32]=period;body[160+:32]=period;body[192+:32]=256;body[224+:16]=1;body[240+:16]=2;
   body[256+:32]=line_time;body[288+:32]=period;body[320+:32]=1;
  end
 endtask
 task compare;
  begin
   #1;cycles=0;
   while(!dut.timing_valid && cycles<15)begin @(negedge clk);cycles=cycles+1;end
   if(!dut.timing_valid || actual!==expected)$fatal(1,"camera comparison AUTO=%0d trial=%0d got=%0d expected=%0d cycles=%0d",AUTO,trial,actual,expected,cycles);
   checks=checks+1;
  end
 endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  // Around both sides of the one-line tolerance at small and large periods;
  // 16e9 is not divisible by 150, so exact integer equality is unreachable.
  for(trial=0;trial<8;trial=trial+1)begin
   @(negedge clk);valid_body(trial<4?105+trial:10665+(trial-4),trial<4?1000000:10000);compare();
   if((actual==0)!==(trial%4==1 || trial%4==2))$fatal(1,"camera tolerance boundary case %0d",trial);
  end
  for(trial=0;trial<512;trial=trial+1)begin
   @(negedge clk);
   if(trial%3==0)begin
    random_value=$random(seed);i=16+random_value%17841;
    valid_body(i,64'd16000000000/(150*i));
    body[7:0]=trial%4;
   end else begin
    valid_body(106,1000000);
    body[256+:32]=$random(seed);body[288+:32]=$random(seed);
    if(trial%7==0)body[352+:32]=1;
   end
   // A pending result for one arithmetic tuple must not authorize another.
   if(trial%8==0)begin repeat(2)@(negedge clk);body[256+:32]=body[256+:32]+1;end
   compare();
  end
  @(negedge clk);valid_body(106,1000000);compare();saved=body;
  body[352]=1;#1;if(actual!=11)$fatal(1,"cached timing bypassed live reserved check");
  body=saved;version=0;#1;if(actual!=11)$fatal(1,"cached timing bypassed version check");version=2;
  id=0;#1;if(actual!=11)$fatal(1,"cached timing bypassed ID check");id=5;
  body=saved;body[256+:32]=999999;submit=1;#1;
  if(actual!=8'hff)$fatal(1,"changed tuple retained approval");
  @(negedge clk);submit=0;
  // The legacy instance may accept this deliberately premature pulse; only
  // the pipelined instance is checked here and both are reset before commit.
  if(dut.state!=0)$fatal(1,"stale tuple was queued");
  rst_n=0;@(negedge clk);rst_n=1;body=saved;compare();
  submit=1;@(negedge clk);submit=0;
  if(dut.queued!==legacy.queued || dut.qv!=2 || dut.qid!=5 || new_status!==old_status)
   $fatal(1,"camera atomic queue mismatch");
  // Later bus mutation cannot alter the accepted command snapshot.
  body=~saved;@(negedge clk);if(dut.queued!==saved)$fatal(1,"queued body changed after acceptance");
  $display("CAMERA_VALIDATION_CASE_PASS AUTO=%0d checks=%0d",AUTO,checks);done=1;
 end
endmodule
module tb_camera_validation_pipeline;
 wire manual_done,auto_done;
 camera_validation_case #(.AUTO(0)) manual_case(manual_done);
 camera_validation_case #(.AUTO(1)) auto_case(auto_done);
 initial begin wait(manual_done&&auto_done);$display("CAMERA_VALIDATION_PIPELINE_PASS");$finish;end
 initial begin #1000000;$fatal(1,"camera validation timeout");end
endmodule
