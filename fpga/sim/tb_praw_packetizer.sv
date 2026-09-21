`timescale 1ns/1ps
// Purpose: source/consumer BFMs test actual packet bytes, stalls, faults and reset.
module tb_praw_packetizer;
 reg clk=0,reset_n=0;always #4 clk=~clk;
 reg start=0,pvalid=0,plast=0,dready=0,ready=0;
 reg [7:0] pdata=0,ptype=1,bayer=1;
 reg [15:0] width=1,height=1;
 reg [63:0] epoch=64'h0102030405060708,fid=0;
 wire fready,pready,ds,pv,done,error;wire [7:0] data;wire [15:0] length;
 wire [3:0] code;wire [31:0] packets;
 integer cycle=0,packet_count=0,byte_count=0,remaining=0,expected=0,errors=0;
 integer hexfile,lenfile,descfile,done_count=0;
 reg [7:0] held;reg was_stalled=0,enable_sink=1,record=1;
 praw_packetizer #(.INPUT_TIMEOUT(60)) dut(
  .clk(clk),.reset_n(reset_n),.frame_start(start),.frame_ready(fready),
  .stream_epoch(epoch),.frame_id(fid),.param_version(32'h10203040),.descriptor_id(32'h55667788),
  .width(width),.height(height),.packet_type(ptype),.bayer_code(bayer),
  .pixel_valid(pvalid),.pixel_last(plast),.pixel_data(pdata),.pixel_ready(pready),
  .datagram_start(ds),.datagram_ready(dready),.datagram_length(length),
  .payload_valid(pv),.payload_ready(ready),.payload_data(data),
  .frame_done(done),.frame_error(error),.error_code(code),.packets_emitted(packets));
 // Purpose: deterministic backpressure while checking stable valid/data.
 always @(negedge clk) begin
  cycle=cycle+1;dready=enable_sink && cycle%7!=0 && remaining==0;
  ready=enable_sink && cycle%5!=0 && cycle%11!=0;
 end
 always @(posedge clk)begin
  if(!reset_n)begin remaining=0;was_stalled=0;end
  else begin
   if(was_stalled && (!pv || data!==held))$fatal(1,"PRAW_FAIL output changed while stalled");
   was_stalled=pv && !ready;held=data;
   if(ds && dready)begin
    if(remaining!=0 || length<65 || length>1464)$fatal(1,"PRAW_FAIL datagram boundary");
    remaining=length;packet_count=packet_count+1;if(record)$fdisplay(lenfile,"%0d",length);
   end
   if(pv && ready)begin
    if(remaining==0)$fatal(1,"PRAW_FAIL unsolicited payload");
    remaining=remaining-1;byte_count=byte_count+1;if(record)$fdisplay(hexfile,"%02x",data);
   end
   if(error)errors=errors+1;
   if(done)done_count=done_count+1;
  end
 end
 task begin_frame(input integer ww,hh,tt,bb,input [63:0] id);
  begin wait(fready);@(negedge clk);width=ww;height=hh;ptype=tt;bayer=bb;fid=id;start=1;
   @(negedge clk);start=0;end
 endtask
 task put(input integer value,input bit last);
  begin
   // Keep a byte stable until accepted, with deterministic source bubbles.
   @(negedge clk);pvalid=1;pdata=value;plast=last;
   do @(posedge clk);while(!pready);
   @(negedge clk);pvalid=0;plast=0;
  end
 endtask
 task good_frame(input integer ww,hh,tt,bb,input [63:0] id);
  integer i,size,previous_done;
  begin size=ww*hh*(tt==1 ? 1 : 3);previous_done=done_count;
   begin_frame(ww,hh,tt,bb,id);
   $fdisplay(descfile,"%0d %0d %0d %0d %0d",ww,hh,tt,bb,id);
   // Mutating live metadata cannot alter the frame descriptor already latched.
   width=99;height=99;fid=64'hdeadbeef;
   for(i=0;i<size;i=i+1)put((i*17+id)&255,i==size-1);
   wait(fready);if(done_count!=previous_done+1)$fatal(1,"PRAW_FAIL no final completion");
  end
 endtask
 integer before_error,before_packets;
 initial begin
  hexfile=$fopen("praw_packets.hex","w");lenfile=$fopen("praw_lengths.txt","w");
  descfile=$fopen("praw_frames.txt","w");
  repeat(5)@(negedge clk);reset_n=1;
  good_frame(1,1,1,1,1);good_frame(1400,1,1,2,2);good_frame(1401,1,1,3,3);
  good_frame(17,19,2,0,4);good_frame(31,47,3,0,5);
  good_frame(1920,1080,1,4,6);
  before_error=errors;before_packets=packet_count;
  begin_frame(0,1,1,1,100);repeat(3)@(negedge clk);
  begin_frame(2,2,1,0,101);repeat(3)@(negedge clk);
  begin_frame(65535,65535,1,1,102);repeat(3)@(negedge clk);
  begin_frame(2,2,9,0,103);repeat(3)@(negedge clk);
  if(errors!=before_error+4)$fatal(1,"PRAW_FAIL descriptor rejection");
  begin_frame(2,2,1,1,104);put(1,1);wait(fready);
  begin_frame(1,1,1,1,105);put(1,0);wait(fready);
  begin_frame(2,2,1,1,106);wait(fready);
  if(errors!=before_error+7 || packet_count!=before_packets)$fatal(1,"PRAW_FAIL fault publication");
  // Reset a partially filled bank: no old packet is emitted after reset.
  begin_frame(16,1,1,1,107);put(1,0);@(negedge clk);reset_n=0;
  repeat(4)@(negedge clk);reset_n=1;repeat(5)@(negedge clk);
  good_frame(3,2,1,1,7);
  $fclose(hexfile);$fclose(lenfile);$fclose(descfile);
  $display("PRAW_PACKETIZER_PASS packets=%0d bytes=%0d errors=%0d",packet_count,byte_count,errors);$finish;
 end
 initial begin #200000000;$fatal(1,"PRAW_TIMEOUT");end
endmodule
