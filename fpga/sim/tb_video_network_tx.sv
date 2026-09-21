`timescale 1ns/1ps
// Purpose: drive complete synthetic frames through the actual PRAW + MAC RTL.
// Captured GMII is parsed independently and decoded by the unchanged PC host.
module tb_video_network_tx;
 reg clk=0;always #4 clk=~clk;
 reg reset_n=0,enable=0,start=0,valid=0,last=0;reg [7:0] data=0;
 reg [63:0] epoch=64'h1020304050607080,fid=0;
 reg [31:0] param_v=7,descriptor=99;reg [15:0] w=0,h=0;
 reg [7:0] kind=1,bayer=1;
 reg [47:0] smac=0,dmac=0;reg [31:0] sip=0,dip=0;reg [15:0] sport=0,dport=0;
 wire ready,pready,fdone,ferror,busy,mdone,merror,en,er;wire [7:0] txd;
 wire [3:0] code;wire [31:0] queued,sent;
 video_network_tx dut(.clk(clk),.reset_n(reset_n),.enable(enable),
  .frame_start(start),.frame_ready(ready),.stream_epoch(epoch),.frame_id(fid),
  .param_version(param_v),.descriptor_id(descriptor),.width(w),.height(h),
  .packet_type(kind),.bayer_code(bayer),.pixel_valid(valid),.pixel_last(last),
  .pixel_data(data),.pixel_ready(pready),.src_mac(smac),.dst_mac(dmac),
  .src_ip(sip),.dst_ip(dip),.src_port(sport),.dst_port(dport),
  .gmii_txd(txd),.gmii_tx_en(en),.gmii_tx_er(er),.frame_done(fdone),
  .frame_error(ferror),.error_code(code),.mac_busy(busy),.mac_done(mdone),
  .mac_error(merror),.packets_queued(queued),.packets_sent(sent));
 integer hexfile,lenfile,descfile,perf,wire_length=0,wire_packets=0;
 integer idle_cycles=100,cycle=0,frame_completions=0;
 reg was_en=0;

 // Purpose: sample emitted GMII including preamble and FCS, with an independent
 // minimum IFG assertion. No simulated packet bytes are invented by this sink.
 always @(posedge clk)begin
  #1;cycle=cycle+1;
  if(reset_n && (ferror || merror || er))$fatal(1,"VIDEO_NET_FAIL unexpected error");
  if(fdone)frame_completions=frame_completions+1;
  if(en)begin
   if(!was_en)begin
    if(idle_cycles<12)$fatal(1,"VIDEO_NET_FAIL IFG %0d",idle_cycles);
    wire_length=0;
   end
   $fwrite(hexfile,"%02x\n",txd);wire_length=wire_length+1;idle_cycles=0;
  end else begin
   idle_cycles=idle_cycles+1;
   if(was_en)begin
    $fwrite(lenfile,"%0d\n",wire_length);wire_packets=wire_packets+1;
   end
  end
  was_en=en;
 end

 // Purpose: ready/valid source remains stable under backpressure and supplies a
 // byte every available clock. Mid-frame changes must not alter latched headers.
 task send_frame(input integer width_i,height_i,kind_i,bayer_i,id_i);
  integer i,total,first_cycle,last_cycle;
  begin
   total=width_i*height_i*((kind_i==1)?1:3);
   @(negedge clk);enable=1;w=width_i;h=height_i;kind=kind_i;bayer=bayer_i;fid=id_i;
   epoch=64'h1020304050607080;param_v=7;descriptor=99;
   smac=48'h020000000001+id_i;dmac=48'h020000001001+id_i;
   sip=32'hc0000201;dip=32'hc6336402;sport=50001;dport=50000;
   start=1;
   @(posedge clk);while(!ready)@(posedge clk);
   first_cycle=cycle;
   @(negedge clk);start=0;valid=1;
   for(i=0;i<total;i=i+1)begin
    data=(i*17+id_i)&255;last=(i==total-1);
    @(posedge clk);while(!pready)@(posedge clk);
    @(negedge clk);
    if(i==100)begin
     epoch=0;fid=0;w=0;h=0;param_v=0;descriptor=0;bayer=0;kind=0;
     smac=0;dmac=0;sip=0;dip=0;sport=0;dport=0;enable=0;
    end
   end
   valid=0;last=0;
   wait(fdone);@(negedge clk);wait(!busy);repeat(3)@(negedge clk);
   last_cycle=cycle;
   $fwrite(descfile,"%0d %0d %0d %0d %0d\n",id_i,width_i,height_i,kind_i,bayer_i);
   $fwrite(perf,"%0d %0d %0d\n",id_i,total,last_cycle-first_cycle);
   if(id_i==22 && last_cycle-first_cycle>=4166666)
    $fatal(1,"VIDEO_NET_FAIL insufficient simulated RAW1080p30 throughput");
  end
 endtask

 // Purpose: exercise disabled admission, small RAW/RGB frames, full 1080p, and
 // draining an accepted frame after enable falls. Physical PHY is not simulated.
 initial begin
  hexfile=$fopen("video_gmii.hex","w");lenfile=$fopen("video_gmii_lengths.txt","w");
  descfile=$fopen("video_frames.txt","w");perf=$fopen("video_cycles.txt","w");
  repeat(5)@(negedge clk);reset_n=1;start=1;
  repeat(10)begin @(negedge clk);if(ready || en)$fatal(1,"VIDEO_NET_FAIL disabled admission");end
  start=0;send_frame(1,1,1,1,20);send_frame(17,19,2,0,21);send_frame(1920,1080,1,4,22);
  if(wire_packets!=1484 || sent!=1484 || queued!=1484 || frame_completions!=3)
   $fatal(1,"VIDEO_NET_FAIL counters packets=%0d sent=%0d queued=%0d frames=%0d",wire_packets,sent,queued,frame_completions);
  $fclose(hexfile);$fclose(lenfile);$fclose(descfile);$fclose(perf);
  $display("VIDEO_NETWORK_PASS frames=3 packets=%0d cycles=%0d",wire_packets,cycle);$finish;
 end
 initial begin #100000000;$fatal(1,"VIDEO_NETWORK_TIMEOUT");end
endmodule
