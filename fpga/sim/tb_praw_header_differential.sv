`timescale 1ns/1ps
// Compare actual old/new packet engines on every edge, including invalid output
// bytes and counters. Exercise all header offsets, odd/even payloads, two-bank
// overlap, backpressure, rejected descriptors and cancellation during preparation.
module tb_praw_header_differential;
 parameter BANKS=2;
 reg clk=0; always #4 clk=~clk;
 reg rst_n=0,flush=0,desc_valid=0,data_valid=0,out_ready=0;
 reg [511:0] header=0;
 reg [10:0] length=0;
 reg [7:0] data=0;
 wire ar,br,adr,bdr,av,bv,al,bl;
 wire [7:0] ad,bd;
 wire [31:0] ap,bp,asent,bsent,ae,be;
 wire [1:0] ao,bo;
 reg [31:0] rng=32'h12345678;
 integer cycles=0,packets=0,header_accepts=0,stalls=0,overlap=0;
 reg [63:0] offsets=0;
 reg random_ready=1;
 // Identical dynamic descriptors and endpoints reach both independently stored
 // instances; no internal force or golden signal drives the candidate.
 praw_udp_tx #(.PACKET_BANKS(BANKS)) dut(
  .clk(clk),.rst_n(rst_n),.flush(flush),.desc_valid(desc_valid),.desc_ready(ar),.praw_header(header),
  .payload_bytes(length),.local_mac(48'h123456789abc),.peer_mac(48'hdef012345678),
  .local_ip(32'hc0a80105),.peer_ip(32'hc0a80109),.local_port(16'd12001),.peer_port(16'd12002),
  .data_valid(data_valid),.data_ready(adr),.data(data),.out_valid(av),.out_ready(out_ready),
  .out_data(ad),.out_last(al),.prepared_packets(ap),.sent_packets(asent),.rejected(ae),.occupied(ao));
 baseline_praw_udp_tx #(.PACKET_BANKS(BANKS)) refdut(
  .clk(clk),.rst_n(rst_n),.flush(flush),.desc_valid(desc_valid),.desc_ready(br),.praw_header(header),
  .payload_bytes(length),.local_mac(48'h123456789abc),.peer_mac(48'hdef012345678),
  .local_ip(32'hc0a80105),.peer_ip(32'hc0a80109),.local_port(16'd12001),.peer_port(16'd12002),
  .data_valid(data_valid),.data_ready(bdr),.data(data),.out_valid(bv),.out_ready(out_ready),
  .out_data(bd),.out_last(bl),.prepared_packets(bp),.sent_packets(bsent),.rejected(be),.occupied(bo));
 // Reproducible unrelated ready toggles cover stable output under prolonged
 // stalls. Counters record coverage before state updates at each active edge.
 always @(negedge clk) begin
  rng=(rng<<1)^((rng[31])?32'h04c11db7:0);
  out_ready=random_ready ? (rng[3:0]==0) : 1;
 end
 always @(posedge clk) begin
  if(rst_n&&!flush) begin
   if(refdut.accept && refdut.wp<64) begin offsets[refdut.wp]=1;header_accepts=header_accepts+1;end
   if(av&&!out_ready)stalls=stalls+1;
   if(ao==2)overlap=overlap+1;
   if(av&&out_ready&&al)packets=packets+1;
  end
  #1;cycles=cycles+1;
  if({ar,adr,av,ad,al,ap,asent,ae,ao} !== {br,bdr,bv,bd,bl,bp,bsent,be,bo})
   $fatal(1,"PRAW outputs differ at cycle %0d",cycles);
  if(cycles>1000000)$fatal(1,"PRAW differential timeout");
 end
 task descriptor(input integer size,input integer bad,input integer tag);
  integer j;
  begin
   @(negedge clk);while(!ar)@(negedge clk);
   for(j=0;j<64;j=j+1)header[j*8+:8]=(j*17+tag*37)&255;
   length=size;header[48*8+:16]=size;header[56*8+:32]=0;
   if(bad==1)header[56*8+:32]=32'hdeadbeef;
   if(bad==2)header[48*8+:16]=size+1;
   desc_valid=1;@(posedge clk);@(negedge clk);desc_valid=0;
  end
 endtask
 task payload(input integer size,input integer tag);
  integer j;
  begin
   j=0;
   while(j<size)begin
    @(negedge clk);data_valid=(rng[2:0]!=0);data=(j*29+tag*11)&255;
    @(posedge clk);if(data_valid&&adr)j=j+1;
   end
   @(negedge clk);data_valid=0;
  end
 endtask
 integer k,size;
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  // Known malformed descriptors must reject before touching packet storage.
  descriptor(0,0,1);descriptor(1401,0,2);descriptor(17,1,3);descriptor(17,2,4);
  repeat(2)@(negedge clk);if(ae!=4)$fatal(1,"Rejected-descriptor coverage missing");
  // Flush interrupts the private header shift, then a fresh descriptor must
  // replace the entire capture. Test every possible cancellation offset.
  for(k=0;k<64;k=k+1)begin
   descriptor(9,0,k);repeat(k)@(negedge clk);flush=1;
   @(negedge clk);flush=0;
  end
  // Asynchronous reset must also discard a partially shifted capture. Sweep
  // all byte offsets before the final uninterrupted packet sequence.
  for(k=0;k<64;k=k+1)begin
   descriptor(11,0,k+200);repeat(k)@(negedge clk);rst_n=0;
   repeat(2)@(negedge clk);rst_n=1;
  end
  for(k=0;k<32;k=k+1)begin
   case(k%8)
    0:size=1;1:size=2;2:size=63;3:size=64;
    4:size=65;5:size=1399;6:size=1400;default:size=301;
   endcase
   descriptor(size,0,k+100);payload(size,k);
  end
  random_ready=0;
  while(ao!=0 || av)@(negedge clk);
  repeat(3)@(negedge clk);
  if(packets!=32 || offsets!=64'hffffffffffffffff || stalls==0 || (BANKS==2&&overlap==0))
   $fatal(1,"PRAW coverage incomplete packets=%0d offsets=%h stalls=%0d overlap=%0d",packets,offsets,stalls,overlap);
  $display("PRAW_HEADER_DIFFERENTIAL_PASS banks=%0d cycles=%0d packets=%0d header_accepts=%0d stalls=%0d overlap=%0d",BANKS,cycles,packets,header_accepts,stalls,overlap);
  $finish;
 end
endmodule
