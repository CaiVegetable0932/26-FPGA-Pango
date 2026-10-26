`timescale 1ns/1ps
// Full 1080p RAW DDR-stride -> bounded reader -> network -> independent host
// byte scoreboard. Native adapter contract includes randomized bounded service
// delays, bursts, completion ACK and nonzero row padding; no real DDR/PHY.
module tb_raw_network #(parameter BANKS=2);
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,start=0,cancel=0,resolve=0;
 reg [7:0] rx_data=0;reg rx_dv=0;reg [7:0] arp_vector [0:71];
 wire start_ready,reader_done,reader_failed,req_valid,req_ready,r_ready,dma_done_ready,dma_cancel;
 wire [31:0] req_addr;wire [4:0] req_beats;
 reg r_valid=0,dma_done=0;reg [255:0] r_data=0;
 wire byte_valid,byte_ready;wire [7:0] byte_data;
 wire frame_ready,release_valid,failed,stream_cancel,tx_en,tx_er;
 wire [7:0] tx_data;wire [31:0] sent_packets,complete_frames,failed_frames;
 reg dma_drained=1;
 integer state=0,wait_count=0,beat=0,beats=0,addr=0,seed=17;
 integer cycles=0,begin_cycle=0,j,position,row,col,fd,cf,packets=0,gap=0;
 reg was_en=0;
 assign req_ready=state==0;
 raw_dma_reader reader(.clk(clk),.rst_n(rst_n),.start(start && frame_ready),.start_ready(start_ready),
  .base_addr(32'h03000000),.slot_begin(32'h03000000),.slot_end(32'h03400000),
  .cancel(stream_cancel),.done(reader_done),.failed(reader_failed),
  .req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),.req_beats(req_beats),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.dma_done(dma_done),.dma_done_ready(dma_done_ready),
  .dma_error(1'b0),.dma_cancel(dma_cancel),.byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data));
 raw_network_service #(.PACKET_BANKS(BANKS)) tx(.clk(clk),.rst_n(rst_n),.now_us(64'(cycles/125)),.gigabit_link_up(1'b1),.resolve(resolve),.cancel(cancel),
  .frame_valid(start && start_ready),.frame_ready(frame_ready),.epoch(64'h0102030405060708),.frame_id(64'd19),
  .param_version(32'd7),.descriptor_id(32'h12345678),.bayer_code(8'd4),
  .local_mac(48'h020000000001),
  .local_ip(32'hc0a85003),.peer_ip(32'hc0a85002),.local_port(16'd50001),.peer_port(16'd50000),
  .byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data),
  .dma_cancel(stream_cancel),.dma_drained(dma_drained),.release_valid(release_valid),.release_ready(1'b1),
  .failed(failed),.rx_data(rx_data),.rx_dv(rx_dv),.rx_er(1'b0),.peer_valid(),.resolution_failed(),
  .tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),.sent_packets(sent_packets),
  .complete_frames(complete_frames),.failed_frames(failed_frames));
 // Contract model: native read completion only after all buffered beats consumed.
 always @(negedge clk) begin
  if(rst_n) begin
   r_valid=0;dma_done=0;
   case(state)
    1: if(wait_count==0) state=2;else wait_count=wait_count-1;
    2: begin
     for(j=0;j<32;j=j+1) begin
      position=addr+beat*32+j-32'h03000000;row=position/2048;col=position%2048;
      r_data[j*8+:8]=(col<1920)?((row*7+col*3+17)&255):8'he7;
     end
     r_valid=1;
    end
    3: dma_done=1;
   endcase
  end
 end
 always @(posedge clk) if(rst_n) begin
  cycles=cycles+1;
  if(start) begin begin_cycle=cycles;dma_drained<=0;end
  if(reader_done) begin if(reader_failed) $fatal(1,"reader failed");dma_drained<=1;end
  if(req_valid && req_ready) begin
   if(req_beats==0 || req_beats>16 || (req_addr[11:0]+req_beats*32)>4096) $fatal(1,"burst boundary");
   addr=req_addr;beats=req_beats;beat=0;wait_count=(cycles%73)+40;state<=1;
  end else if(r_valid && r_ready) begin beat=beat+1;if(beat==beats) state<=3;end
  else if(dma_done && dma_done_ready) state<=0;
  if(cycles>8000000) $fatal(1,"network timeout");
  if(cycles==10000 && $test$plusargs("debug")) begin
   // This fixture keeps the generic unaligned reader mode for offset coverage.
   $display("debug reader=%0d adapter=%0d remain=%0d beat=%0d bytes=%0d unpackleft=%0d loaded=%0d txfeed=%0d",reader.state,state,reader.remaining,beat,reader.chunk_pos,reader.unpack.unaligned_rows.left,reader.loaded,tx.raw.feed);
   $finish;
  end
 end
 // Sample registered GMII after NBA, preserve every Ethernet byte and IFG.
 always @(negedge clk) if(rst_n) begin
  if(tx_er) $fatal(1,"unexpected GMII TX error");
  if(tx_en) begin
   if(!was_en && packets!=0 && gap<12) $fatal(1,"short IFG");
   $fwrite(fd,"%02x",tx_data);gap=0;
  end else begin
   gap=gap+1;
   if(was_en) begin $fwrite(fd,"\n");packets=packets+1;end
  end
  was_en=tx_en;
 end
 initial begin
  fd=$fopen("wire.hex","w");
  $readmemh("arp_reply.hex",arp_vector);
  repeat(5) @(negedge clk);rst_n=1;
  resolve=1;@(negedge clk);resolve=0;wait(packets==1);
  for(j=0;j<72;j=j+1) begin @(negedge clk);rx_data=arp_vector[j];rx_dv=1;end
  @(negedge clk);rx_dv=0;wait(frame_ready);
  @(negedge clk);start=1;@(negedge clk);start=0;
  wait(release_valid);@(negedge clk);
  if(failed || complete_frames!=1 || failed_frames!=0 || packets!=1483) $fatal(1,"frame result mismatch");
  cf=$fopen("network_cycles.txt","w");$fwrite(cf,"%0d\n",cycles-begin_cycle);$fclose(cf);$fclose(fd);
  $display("RAW_NETWORK_PASS cycles=%0d packets=%0d",cycles-begin_cycle,packets);$finish;
 end
endmodule
