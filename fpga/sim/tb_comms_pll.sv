`timescale 1ns/1ps
// Purpose: prove native generated GPLL frequency AND actual 90-degree lag.
// No ideal clock substitute; input reference and global reset are the stimulus.
module tb_comms_pll;
 reg reference_clk=0,global_reset_n=0;
 always #4 reference_clk=~reference_clk;
 GTP_GRS GRS_INST(.GRS_N(global_reset_n));
 wire c0,c90,locked;
 comms_pll dut(.clkin1(reference_clk),.rst(~global_reset_n),.clkout0(c0),.clkout1(c90),.lock(locked));
 real last0=-100,previous0=-100;integer checks=0;
 always @(posedge c0)begin previous0=last0;last0=$realtime;end
 initial begin
  #100;global_reset_n=1;wait(locked);repeat(20)@(posedge c0);
  repeat(1000)begin
   @(posedge c90);
   if($realtime-last0<1.99 || $realtime-last0>2.01 || last0-previous0<7.99 || last0-previous0>8.01)
    $fatal(1,"PLL_FAIL phase=%0f period=%0f",$realtime-last0,last0-previous0);
   checks=checks+1;
  end
  $display("COMMS_PLL_PASS checks=%0d period_ns=8 lag_ns=2 native=GTP_GPLL",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"PLL_TIMEOUT");end
endmodule
