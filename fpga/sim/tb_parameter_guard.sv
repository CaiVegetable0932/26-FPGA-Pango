`timescale 1ns/1ps
// Whole-entity CRC and signed range verification before shadow-bank submission.
// The compact 2-word fixture tests the generic guard, not a new camera format.
module tb_parameter_guard;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,submit_valid=0,result_ready=0,format_supported=1;
 reg [63:0] entity={32'hfffffffe,32'd1},lower_bounds={2{32'hfffffff6}},upper_bounds={2{32'd10}};
 reg [31:0] expected_crc=32'hcf8f9871;
 wire submit_ready,result_valid,validated;wire [63:0] result_entity;wire [1:0] reject_reason;
 parameter_entity_guard #(.WORDS(2)) dut(.*);
 task check(input bit expected,input [1:0] reason);
  begin
   wait(submit_ready);@(negedge clk);submit_valid=1;@(negedge clk);submit_valid=0;
   wait(result_valid);@(negedge clk);
   if(validated!=expected || reject_reason!=reason) $fatal(1,"guard result %b %0d",validated,reject_reason);
   result_ready=1;@(negedge clk);result_ready=0;
  end
 endtask
 initial begin
  repeat(5) @(negedge clk);rst_n=1;
  check(1,0);expected_crc=0;check(0,3);expected_crc=32'hcf8f9871;
  upper_bounds[31:0]=0;check(0,2);upper_bounds[31:0]=10;
  format_supported=0;check(0,1);
  $display("PARAMETER_GUARD_PASS crc/range/model");$finish;
 end
 initial begin #100000;$fatal(1,"guard timeout");end
endmodule
