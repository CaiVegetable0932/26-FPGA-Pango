`timescale 1ns/1ps
// Purpose: verify the board's cascaded ETH/FIFO and local RGMII serializer
// reset topology. Both assert immediately; pads release only after the domain
// reset, so no partial early packet can appear at the PHY.
module tb_raw8_eth_reset;
 reg clk=0,async_n=0;
 wire domain_n,pad_n;
 integer edge_count;
 always #4 clk=~clk;
 reset_sync u_domain(.clk(clk),.async_reset_n(async_n),.reset_n(domain_n));
 reset_sync u_pad(.clk(clk),.async_reset_n(domain_n),.reset_n(pad_n));
 task release_and_check;
  begin
   @(negedge clk);async_n=1;
   for(edge_count=1;edge_count<=6;edge_count=edge_count+1)begin
    @(posedge clk);#1;
    if(domain_n!==(edge_count>=3) || pad_n!==(edge_count>=6))
     $fatal(1,"RAW8_ETH_RESET_FAIL edge=%0d domain=%b pad=%b",edge_count,domain_n,pad_n);
   end
  end
 endtask
 initial begin
  repeat(2)@(negedge clk);
  release_and_check();
  // Purpose: a later asynchronous fault must immediately hold both the FIFO
  // domain and the RGMII output pads before either clock can advance.
  #1;async_n=0;#1;
  if(domain_n!==0 || pad_n!==0)$fatal(1,"RAW8_ETH_RESET_FAIL async assertion");
  release_and_check();
  $display("RAW8_ETH_RESET_PASS");$finish;
 end
 initial begin #500;$fatal(1,"RAW8_ETH_RESET_TIMEOUT");end
endmodule
