`timescale 1ns/1ps
// Non-harmonic clocks and stalled consumers prove coherent whole-source-edge
// data and held destination results; no independent counter words are combined.
module tb_counter_snapshot_cdc;
 reg src_clk=0,dst_clk=0;always #4 src_clk=~src_clk;always #6.5 dst_clk=~dst_clk;
 reg src_rst_n=0,dst_rst_n=0,request=0,snapshot_ready=0;reg [31:0] count=0;
 wire request_ready,snapshot_valid;wire [127:0] counters={~count,count*32'd3,count*32'd2,count};wire [127:0] snapshot;
 integer i;reg [127:0] saved;
 always @(posedge src_clk) if(src_rst_n) count<=count+1;
 counter_snapshot_cdc #(.BITS(128)) dut(.*);
 initial begin
  repeat(5) @(negedge src_clk);src_rst_n=1;@(negedge dst_clk);dst_rst_n=1;
  for(i=0;i<50;i=i+1) begin
   wait(request_ready);@(negedge dst_clk);request=1;@(negedge dst_clk);request=0;
   wait(snapshot_valid);@(negedge dst_clk);saved=snapshot;
   if(snapshot[63:32]!=snapshot[31:0]*2 || snapshot[95:64]!=snapshot[31:0]*3 || snapshot[127:96]!=~snapshot[31:0]) $fatal(1,"mixed snapshot");
   repeat(i%7+2) @(negedge dst_clk);
   if(snapshot!=saved || !snapshot_valid || request_ready) $fatal(1,"snapshot hold");
   snapshot_ready=1;@(negedge dst_clk);snapshot_ready=0;
  end
  $display("COUNTER_SNAPSHOT_CDC_PASS snapshots=50");$finish;
 end
 initial begin #100000;$fatal(1,"snapshot timeout");end
endmodule
