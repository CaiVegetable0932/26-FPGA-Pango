`timescale 1ns/1ps
// Purpose: pin-level SCCB register-model tests for RAW8 standby programming,
// every profile readback, streaming enable, wrong identity, NACK and mismatch.
module tb_raw8_startup;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 tri1 scl,sda;
 wire sensor_reset,ready,failed;wire [3:0] error_code;
 wire [6:0] index;wire [7:0] last_read,run_register;
 // Purpose: independently inspect every readback-table address so an AEC
 // output register cannot re-enter the static startup verification loop.
 reg [6:0] table_index=0;wire [23:0] table_value;wire table_last;
 ov5640_raw8_profile table_guard(.index(table_index),.value(table_value),.last(table_last));
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
   if(f==0 && (model.memory[16'h501f]!=3 || model.memory[16'h4300]!=0 ||
      model.memory[16'h3808]!=7 || model.memory[16'h3809]!=8'h80 ||
      model.memory[16'h380a]!=4 || model.memory[16'h380b]!=8'h38 ||
      model.memory[16'h503d]!=0 || run_register!=2))$fatal(1,"RAW8_FAIL profile");
   // Purpose: ensure the geometry experiment reaches SCCB/readback unchanged;
   // this model does not assert that the physical sensor emits1080 rows.
   if(f==0 && model.memory[16'h4004]!=6)$fatal(1,"RAW8_FAIL BLC baseline");
   // Purpose: the module maps sensor D[9:2] to CAM1_D[7:0]. Keep normal
   // pad order; debug rotation 02 injects sensor D[1:0] into the MSBs.
   if(f==0 && model.memory[16'h4745]!=8'h00)$fatal(1,"RAW8_FAIL DVP RAW8 pin mapping");
   // Purpose: assert the modest +8-code AEC window and 5x AGC ceiling while
   // bounding exposure to one frame, so brightness tuning cannot lower fps.
   if(f==0 && (model.memory[16'h3503]!=8'h00 ||
      model.memory[16'h3a00]!=8'h78 || model.memory[16'h3a05]!=8'h30 ||
      {model.memory[16'h3a02],model.memory[16'h3a03]}!=16'h0450 ||
      {model.memory[16'h3a14],model.memory[16'h3a15]}!=16'h0450 ||
      {model.memory[16'h3a18],model.memory[16'h3a19]}!=16'h0050 ||
      model.memory[16'h3a0f]!=8'h80 || model.memory[16'h3a10]!=8'h70 ||
      model.memory[16'h3a1b]!=8'h80 || model.memory[16'h3a1e]!=8'h70 ||
      {model.memory[16'h3a08],model.memory[16'h3a09]}!=16'h0150 ||
      {model.memory[16'h3a0a],model.memory[16'h3a0b]}!=16'h0118))
      $fatal(1,"RAW8_FAIL bounded auto exposure profile");
   // Purpose: independently guard the 8-bit PLL formula and 30fps timing;
   // SCCB readback alone would also accept a consistently wrong register table.
   if(f==0 && (model.memory[16'h3034]!=8'h18 || model.memory[16'h3035]!=8'h11 ||
      model.memory[16'h3036]!=84 || model.memory[16'h3037]!=8'h13 ||
      model.memory[16'h3108]!=1 || {model.memory[16'h380c],model.memory[16'h380d]}!=2500 ||
      {model.memory[16'h380e],model.memory[16'h380f]}!=1120))$fatal(1,"RAW8_FAIL 84MHz 30fps clock profile");
   if(f!=0 && sensor_reset)$fatal(1,"RAW8_FAIL failed sensor not held reset");
   tests=tests+1;repeat(10)@(negedge clk);
  end
 endtask
 initial begin
  // Purpose: dynamic exposure/gain output values must never be compared
  // against constants after streaming starts, or startup can fail at random.
  for(integer n=0;n<=73;n=n+1)begin
   table_index=n[6:0];#1;
   if(table_last !== (n==73) ||
      table_value[23:8]==16'h3500 || table_value[23:8]==16'h3501 ||
      table_value[23:8]==16'h3502 || table_value[23:8]==16'h350a ||
      table_value[23:8]==16'h350b || table_value[23:8]==16'h350c ||
      table_value[23:8]==16'h350d)
      $fatal(1,"RAW8_FAIL volatile AEC register in startup readback");
  end
  run_case(0);run_case(1);run_case(2);run_case(3);
  $display("RAW8_STARTUP_PASS tests=%0d",tests);$finish;
 end
 initial begin #100000000;$fatal(1,"RAW8_TIMEOUT startup");end
endmodule
