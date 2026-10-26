`timescale 1ns/1ps
// Odd/even checksum, header CRC patch, short/maximum payload and overlapping
// banks against a byte-exact host golden stream, including independent FCS.
module tb_praw_packets;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,desc_valid=0,data_valid=0;
 reg [511:0] praw_header=0;reg [10:0] payload_bytes=0;reg [7:0] data=0;
 wire desc_ready,data_ready,out_valid,out_ready,out_last;wire [7:0] out_data,tx_data;wire tx_en,tx_er;
 wire [31:0] prepared_packets,sent_packets,rejected;wire [1:0] occupied;
 reg [7:0] headers [0:63],golden [0:3302];
 integer pos=0,i,j,peak=0,size;
 praw_udp_tx dut(.clk(clk),.rst_n(rst_n),.flush(1'b0),.desc_valid(desc_valid),.desc_ready(desc_ready),.praw_header(praw_header),
  .payload_bytes(payload_bytes),.local_mac(48'h020000000001),.peer_mac(48'h020000000002),
  .local_ip(32'hc0a85003),.peer_ip(32'hc0a85002),.local_port(16'd50001),.peer_port(16'd50000),
  .data_valid(data_valid),.data_ready(data_ready),.data(data),.out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.out_last(out_last),
  .prepared_packets(prepared_packets),.sent_packets(sent_packets),.rejected(rejected),.occupied(occupied));
 ethernet_mac_tx mac(.clk(clk),.rst_n(rst_n),.link_up(1'b1),.in_valid(out_valid),.in_ready(out_ready),.in_data(out_data),.in_last(out_last),
  .tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),.idle(),.frames(),.underruns());
 always @(negedge clk) if(rst_n) begin
  if(occupied>peak) peak=occupied;
  if(tx_er) $fatal(1,"MAC underrun");
  if(tx_en) begin
   if(tx_data!==golden[pos]) $fatal(1,"golden byte %0d %02x != %02x",pos,tx_data,golden[pos]);pos=pos+1;
  end
 end
 initial begin
  $readmemh("tiny_wire.hex",golden);
  repeat(5) @(negedge clk);rst_n=1;
  // Explicit rejection of application CRC prefilled by an untrusted producer.
  praw_header[448+:32]=1;payload_bytes=1;praw_header[384+:16]=1;
  desc_valid=1;@(negedge clk);desc_valid=0;if(rejected!=1) $fatal(1,"bad descriptor accepted");
  for(i=0;i<4;i=i+1) begin
   case(i)
    0:begin size=1;$readmemh("tiny_header_0.hex",headers);end
    1:begin size=31;$readmemh("tiny_header_1.hex",headers);end
    2:begin size=1399;$readmemh("tiny_header_2.hex",headers);end
    3:begin size=1400;$readmemh("tiny_header_3.hex",headers);end
   endcase
   wait(desc_ready);@(negedge clk);
   for(j=0;j<64;j=j+1) praw_header[j*8+:8]=headers[j];
   payload_bytes=size;desc_valid=1;@(negedge clk);desc_valid=0;
   for(j=0;j<size;j=j+1) begin
    @(negedge clk);data_valid=1;data=(j*3+i)&255;
    do @(posedge clk);while(!data_ready);
    @(negedge clk);data_valid=0;
   end
  end
  wait(pos==3303);repeat(30) @(negedge clk);
  if(peak!=2 || prepared_packets!=4 || sent_packets!=4) $fatal(1,"bank overlap");
  $display("PRAW_PACKETS_PASS bytes=%0d peak_banks=%0d",pos,peak);$finish;
 end
 initial begin #100000;$fatal(1,"packet timeout");end
endmodule
