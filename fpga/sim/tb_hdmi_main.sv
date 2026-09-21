`timescale 1ns/1ps
// Purpose: integration-level raster, RGB565, RGB lane/control alignment tests.
// Serializer is a symbol observer, NOT a model/proof of physical TMDS signaling.
module hdmi_tx_oserdes(input pixel_clk, serial_clk, reset_n,
 input [9:0] symbol, output data_p, data_n);
 assign data_p=symbol[0];
 assign data_n=~symbol[0];
endmodule

module tb_hdmi_main;
 reg clk=0;
 always #5 clk=~clk;
 reg lock=0;
 wire rstn;
 hdmi_tx_powerup_reset #(.HOLD_BITS(4)) reset_dut(clk,lock,rstn);
 wire [23:0] pattern;
 wire de,hs,vs;
 hdmi_720p_diagnostic raster(clk,rstn,pattern,de,hs,vs);
 reg [15:0] packed_rgb;
 wire [23:0] expanded;
 hdmi_rgb565_expand expand(packed_rgb,expanded);
 reg [23:0] rgb=0;
 reg enable=0,h=0,v=0;
 hdmi_tx_rgb tx(.pixel_clk(clk),.serial_clk(clk),.reset_n(rstn),
  .rgb(rgb),.data_enable(enable),.hsync(h),.vsync(v));
 reg [26:0] history0=0, history1=0, expected=0;
 integer count=0, pixels=0, hcycles=0, vcycles=0, checks=0;
 reg monitor=0;
 // Inverse transition coding independently verifies RGB bytes, not a duplicate
 // encoder implementation. Control symbols verify HS/VS ordering on blue only.
 function automatic [7:0] decode(input [9:0] symbol);
  reg [7:0] q;
  integer j;
  begin
   q=symbol[9] ? ~symbol[7:0] : symbol[7:0];
   decode[0]=q[0];
   for(j=1;j<8;j=j+1)
    decode[j]=symbol[8] ? q[j]^q[j-1] : ~(q[j]^q[j-1]);
  end
 endfunction
 function automatic [9:0] control(input [1:0] bits);
  case(bits)
   0:control=10'b1101010100; 1:control=10'b0010101011;
   2:control=10'b0101010100; 3:control=10'b1010101011;
  endcase
 endfunction
 always @(posedge clk) begin
  expected=history1; history1=history0; history0={enable,v,h,rgb};
  #2;
  if(monitor && rstn) begin
   if(expected[26]) begin
    if({decode(tx.encoded[2]),decode(tx.encoded[1]),decode(tx.encoded[0])} !== expected[23:0])
     $fatal(1,"RGB lane/pipeline mismatch");
   end else begin
    if(tx.encoded[0] !== control(expected[25:24]) ||
       tx.encoded[1] !== control(0) || tx.encoded[2] !== control(0))
     $fatal(1,"blanking control mismatch");
   end
   if(tx.u_clock_lane.symbol !== 10'b1111100000) $fatal(1,"clock symbol");
   checks=checks+1;
  end
 end
 initial begin
  // Check complete 565 code space, including white/full-range and channel order.
  for(integer i=0;i<65536;i=i+1) begin
   packed_rgb=i; #1;
   if(expanded !== {packed_rgb[15:11],packed_rgb[15:13],packed_rgb[10:5],
     packed_rgb[10:9],packed_rgb[4:0],packed_rgb[4:2]}) $fatal(1,"RGB565");
  end
  @(negedge clk); lock=1;
  repeat(14) begin @(posedge clk); #2; if(rstn) $fatal(1,"early reset release"); end
  repeat(4) @(negedge clk);
  if(!rstn) $fatal(1,"no reset release");
  repeat(4) @(negedge clk);
  monitor=1;
  for(integer i=0;i<1024;i=i+1) begin
   @(negedge clk); rgb=$random; enable=(i%13)>3; h=i[0]; v=i[1];
  end
  // Count exactly one full VS-to-VS period; timing remains live independently
  // of camera frame validity. 1650*750 total clocks, 1280*720 active samples.
  @(posedge vs); @(negedge clk);
  count=0; pixels=0; hcycles=0; vcycles=0;
  repeat(1237500) begin
   count=count+1; if(de) pixels=pixels+1;
   if(hs) hcycles=hcycles+1; if(vs) vcycles=vcycles+1;
   if(de && (raster.x>1279 || raster.y>719)) $fatal(1,"active coordinate");
   @(negedge clk);
  end
  if(pixels!=921600 || hcycles!=30000 || vcycles!=8250) $fatal(1,"720p raster totals");
  lock=0; #2; if(rstn) $fatal(1,"lock loss reset");
  monitor=0;
  repeat(5) @(negedge clk);
  lock=1; repeat(20) @(negedge clk);
  if(!rstn) $fatal(1,"relock");
  $display("HDMI_MAIN_PASS rgb565=65536 raster=1650x750 active=1280x720 rgb_checks=%0d",checks);
  $finish;
 end
 // Bounded simulation; a missing sync edge must fail instead of hanging CI.
 initial begin #40000000; $fatal(1,"watchdog"); end
endmodule
