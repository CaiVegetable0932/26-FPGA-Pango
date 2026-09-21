`timescale 1ns/1ps
// Purpose: actual commissioning source -> PRAW/MAC -> native RGMII pins.
// Reassemble bytes at the PHY's +2 ns sampling point, not from GMII internals.
// Ideal source clock here; native PLL phase has a separate unmodified-model test.
module tb_comms_test_source;
 reg clk=0;always #4 clk=~clk;
 reg rst=0,enable=0;
 GTP_GRS GRS_INST(.GRS_N(rst));
 wire start,ready,valid,last,pready,fdone,ferror,sfault,mbusy,mdone,merror,en,er;
 wire [7:0] data,txd;wire [63:0] fid;wire [31:0] frames,queued,sent;wire [3:0] code;
 comms_test_source source(.clk(clk),.reset_n(rst),.enable(enable),.frame_ready(ready),
  .pixel_ready(pready),.frame_done(fdone),.frame_error(ferror),.frame_start(start),
  .pixel_valid(valid),.pixel_last(last),.pixel_data(data),.frame_id(fid),.fault(sfault),.frames_done(frames));
 video_network_tx net(.clk(clk),.reset_n(rst),.enable(enable),.frame_start(start),.frame_ready(ready),
  .stream_epoch(64'h0102030405060708),.frame_id(fid),.param_version(32'd0),.descriptor_id(32'h54534554),
  .width(16'd1920),.height(16'd1080),.packet_type(8'd1),.bayer_code(8'd1),
  .pixel_valid(valid),.pixel_last(last),.pixel_data(data),.pixel_ready(pready),
  .src_mac(48'h020000000001),.dst_mac(48'h020000000002),.src_ip(32'hc0a80132),.dst_ip(32'hc0a80164),
  .src_port(16'd50001),.dst_port(16'd50000),.gmii_txd(txd),.gmii_tx_en(en),.gmii_tx_er(er),
  .frame_done(fdone),.frame_error(ferror),.error_code(code),.mac_busy(mbusy),.mac_done(mdone),
  .mac_error(merror),.packets_queued(queued),.packets_sent(sent));
 wire txc,ctl;wire [3:0] pins;
 pango_rgmii_tx #(.PHY_TXID(1)) io(.clk125(clk),.clk125_90(clk),.reset_n(rst),.txc_reset_n(rst),
  .gmii_data(txd),.gmii_en(en),.gmii_error(er),.rgmii_txc(txc),.rgmii_ctl(ctl),.rgmii_data(pins));
 integer file_hex,file_lengths,wire_length=0,packets=0,gap=99,cycle=0,start_cycle=0,end_cycle=0;
 reg [3:0] low;reg lo_ctl,previous_en=0;
 // Sample both DDR halves 2 ns after the FORWARDED pin edges, emulating TXID.
 always @(posedge txc)begin #2;low=pins;lo_ctl=ctl;end
 always @(negedge txc)begin
  #2;
  if(rst)begin
   if(lo_ctl!==ctl)$fatal(1,"TEST_SOURCE_FAIL TX_ER");
   if(lo_ctl)begin
    if(!previous_en)begin
     if(gap<12)$fatal(1,"TEST_SOURCE_FAIL IFG");wire_length=0;
    end
    $fwrite(file_hex,"%02x\n",{pins,low});wire_length=wire_length+1;gap=0;
   end else begin
    gap=gap+1;
    if(previous_en)begin $fwrite(file_lengths,"%0d\n",wire_length);packets=packets+1;end
   end
   previous_en=lo_ctl;
  end
 end
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rst && (sfault||ferror||merror||er))$fatal(1,"TEST_SOURCE_FAIL error");
  if(start&&ready)start_cycle=cycle;
  if(fdone)end_cycle=cycle;
 end
 initial begin
  file_hex=$fopen("test_rgmii.hex","w");file_lengths=$fopen("test_rgmii_lengths.txt","w");
  #40;rst=1;repeat(100)@(negedge clk);
  if(start||en)$fatal(1,"TEST_SOURCE_FAIL disabled");
  enable=1;wait(valid);repeat(4000)@(negedge clk);enable=0;
  // Loss of admission cannot truncate an already admitted source frame.
  wait(frames==1);wait(!mbusy);repeat(20)@(negedge clk);
  if(packets!=1482 || sent!=1482 || queued!=1482 || fid!=2)
   $fatal(1,"TEST_SOURCE_FAIL packet/frame counters %0d",packets);
  if(end_cycle-start_cycle>=4166667)$fatal(1,"TEST_SOURCE_FAIL 30fps budget");
  repeat(100)@(negedge clk);if(en||start)$fatal(1,"TEST_SOURCE_FAIL stopped admission");
  $fclose(file_hex);$fclose(file_lengths);
  $display("COMMS_SOURCE_PASS frames=1 packets=%0d pixels=2073600 cycles=%0d",packets,end_cycle-start_cycle);$finish;
 end
 initial begin #50000000;$fatal(1,"TEST_SOURCE_TIMEOUT");end
endmodule
