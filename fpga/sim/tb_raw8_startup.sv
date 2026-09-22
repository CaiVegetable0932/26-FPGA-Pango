`timescale 1ns/1ps
// Purpose: pin-level SCCB register-model tests for RAW8 standby programming,
// every profile readback, streaming enable, wrong identity, NACK and mismatch.
module tb_raw8_startup;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 tri1 scl,sda;
 wire sensor_reset,ready,failed;wire [3:0] error_code;
 wire [6:0] index;wire [7:0] last_read,run_register;
 integer fault=0,writes,reads,starts,tests=0;
 ov5640_raw8_startup #(.SYS_CLK(3200),.SCCB_CLK(100),.RESET_CYCLES(10),
  .BOOT_CYCLES(20),.WRITE_WAIT(8),.SOFT_RESET_WAIT(20),.SETTLE_CYCLES(30)) dut(
  .clk(clk),.rst_n(rst_n),.scl(scl),.sda(sda),.reset_n(sensor_reset),
  .ready(ready),.failed(failed),.error_code(error_code),.verify_index(index),.last_read(last_read));
 ov5640_register_model model(sensor_reset,scl,sda,fault,writes,reads,starts,run_register);
 task run_case(input integer f);
  begin
   @(negedge clk);rst_n=0;fault=f;repeat(5)@(negedge clk);rst_n=1;
   wait(ready || failed);
   if(ready!==(f==0))$fatal(1,"RAW8_FAIL startup fault=%0d error=%0d index=%0d",f,error_code,index);
   if(f==0 && (model.memory[16'h501f]!=4 || model.memory[16'h4300]!=0 ||
      model.memory[16'h3808]!=7 || model.memory[16'h3809]!=8'h80 ||
      model.memory[16'h380a]!=4 || model.memory[16'h380b]!=8'h38 ||
      model.memory[16'h503d]!=0 || run_register!=2))$fatal(1,"RAW8_FAIL profile");
   if(f!=0 && sensor_reset)$fatal(1,"RAW8_FAIL failed sensor not held reset");
   tests=tests+1;repeat(10)@(negedge clk);
  end
 endtask
 initial begin
  run_case(0);run_case(1);run_case(2);run_case(3);
  $display("RAW8_STARTUP_PASS tests=%0d",tests);$finish;
 end
 initial begin #100000000;$fatal(1,"RAW8_TIMEOUT startup");end
endmodule
