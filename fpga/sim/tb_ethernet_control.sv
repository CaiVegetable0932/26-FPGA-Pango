`timescale 1ns/1ps
// ARP through full FCS-verified MAC RX, finite retry round, bad FCS/drop and
// link invalidation. Clause22 PHY model checks turnaround release/data capture.
module tb_ethernet_control;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,link_up=1,resolve=0;
 reg [63:0] now_us=0;always @(posedge clk) now_us<=now_us+1;
 reg [7:0] rx_data=0;reg rx_dv=0,rx_er=0;
 wire rx_valid,rx_last;wire [7:0] rx_body;
 wire peer_valid,resolution_failed,tx_valid,tx_last;wire [47:0] peer_mac;wire [7:0] tx_data;
 wire [31:0] rejected_rx,dropped_replies,requests,good_frames,bad_frames,overruns;
 reg request_valid=0,request_read=1,response_ready=0;
 reg [4:0] phy_addr=1,reg_addr=2;reg [15:0] write_data=16'h1234;
 wire request_ready,mdc,mdio_o,mdio_oe,response_valid,turnaround_error;wire [15:0] read_data;
 wire mdio_i=(mdio.pos==47)?1'b0:(mdio.pos>=48 ? ((16'ha5c3>>(63-mdio.pos))&1):1'b1);
 reg [7:0] vector [0:71];integer i,ctrl_pos=0,ctrl_packets=0;
 ethernet_mac_rx rx(.clk(clk),.rst_n(rst_n),.link_up(link_up),.rx_data(rx_data),.rx_dv(rx_dv),.rx_er(rx_er),
  .out_valid(rx_valid),.out_ready(1'b1),.out_data(rx_body),.out_last(rx_last),
  .good_frames(good_frames),.bad_frames(bad_frames),.overruns(overruns));
 arp_peer #(.RETRY_US(500),.TTL_US(10000)) arp(.clk(clk),.rst_n(rst_n),.now_us(now_us),.link_up(link_up),.resolve(resolve),
  .local_mac(48'h020000000001),.local_ip(32'hc0a85003),.peer_ip(32'hc0a85002),
  .rx_valid(rx_valid),.rx_data(rx_body),.rx_last(rx_last),.rx_packet_good(1'b1),
  .peer_valid(peer_valid),.peer_mac(peer_mac),.resolution_failed(resolution_failed),
  .tx_valid(tx_valid),.tx_ready(1'b1),.tx_data(tx_data),.tx_last(tx_last),
  .rejected_rx(rejected_rx),.dropped_replies(dropped_replies),.requests(requests));
 mdio_clause22 #(.HALF_PERIOD(2)) mdio(.*);
 always @(posedge clk) begin
  if(tx_valid) begin
   if(ctrl_pos<6 && tx_data!=8'hff) $fatal(1,"ARP broadcast");
   if(ctrl_pos==20 && tx_data!=0 || ctrl_pos==21 && tx_data!=1) $fatal(1,"ARP opcode");
   if(tx_last) begin if(ctrl_pos!=41) $fatal(1,"ARP length");ctrl_packets=ctrl_packets+1;ctrl_pos=0;end
   else ctrl_pos=ctrl_pos+1;
  end
  if(mdio.active && request_read && mdio.pos>=46 && mdio_oe) $fatal(1,"MDIO TA contention");
 end
 task resolve_peer;
  begin @(negedge clk);resolve=1;@(negedge clk);resolve=0;end
 endtask
 task incoming(input bit corrupt);
  begin
   for(i=0;i<72;i=i+1) begin @(negedge clk);rx_dv=1;rx_data=vector[i] ^ ((corrupt && i==71)?8'h01:8'h00);end
   @(negedge clk);rx_dv=0;repeat(70) @(negedge clk);
  end
 endtask
 initial begin
  $readmemh("arp_reply.hex",vector);repeat(5) @(negedge clk);rst_n=1;
  resolve_peer();wait(ctrl_packets==1);incoming(1);
  if(peer_valid || bad_frames!=1) $fatal(1,"bad Ethernet FCS accepted");
  incoming(0);if(!peer_valid || peer_mac!=48'h020000000002 || good_frames!=1) $fatal(1,"ARP resolve");
  link_up=0;@(negedge clk);link_up=1;resolve_peer();wait(resolution_failed);
  if(requests!=4 || ctrl_packets!=4 || peer_valid) $fatal(1,"ARP retries not bounded");
  @(negedge clk);request_valid=1;@(negedge clk);request_valid=0;wait(response_valid);@(negedge clk);
  if(read_data!=16'ha5c3 || turnaround_error) $fatal(1,"MDIO read");
  response_ready=1;@(negedge clk);response_ready=0;
  request_read=0;request_valid=1;@(negedge clk);request_valid=0;wait(response_valid);
  if(turnaround_error) $fatal(1,"MDIO write");
  $display("ETHERNET_CONTROL_PASS arp_requests=%0d good=%0d bad=%0d mdio=a5c3",requests,good_frames,bad_frames);$finish;
 end
 initial begin #100000;$fatal(1,"Ethernet control timeout");end
endmodule
