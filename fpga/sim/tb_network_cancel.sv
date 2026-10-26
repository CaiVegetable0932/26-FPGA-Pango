`timescale 1ns/1ps
// Mid-packet and pre-packet cancellation waits for explicit DDR drain, held
// release ACK, timeout and link loss recovery; source epoch survives reconnect.
module tb_network_cancel;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,link_up=1,peer_resolved=1,cancel=0,frame_valid=0;
 reg byte_valid=0,dma_drained=0,release_ready=0;reg [7:0] byte_data=0;
 wire frame_ready,byte_ready,dma_cancel,release_valid,failed,tx_en,tx_er;wire [7:0] tx_data;
 wire [31:0] sent_packets,complete_frames,failed_frames;integer i;
 raw_frame_tx #(.WIDTH(1920),.HEIGHT(3),.INPUT_TIMEOUT(200)) dut(
  .clk(clk),.rst_n(rst_n),.link_up(link_up),.peer_resolved(peer_resolved),.cancel(cancel),
  .frame_valid(frame_valid),.frame_ready(frame_ready),.epoch(64'd17),.frame_id(64'd23),
  .param_version(32'd7),.descriptor_id(32'd1),.bayer_code(8'd4),
  .local_mac(48'h020000000001),.peer_mac(48'h020000000002),.local_ip(32'hc0a85003),.peer_ip(32'hc0a85002),
  .local_port(16'd50001),.peer_port(16'd50000),.byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data),
  .dma_cancel(dma_cancel),.dma_drained(dma_drained),.release_valid(release_valid),.release_ready(release_ready),
  .failed(failed),.tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),.body_valid(),.body_ready(1'b0),.body_data(),.body_last(),.external_mac_idle(1'b0),
  .sent_packets(sent_packets),.complete_frames(complete_frames),.failed_frames(failed_frames));
 task begin_frame;
  begin wait(frame_ready);@(negedge clk);frame_valid=1;dma_drained=0;@(negedge clk);frame_valid=0;end
 endtask
 task release_frame;
  begin
   repeat(20) @(negedge clk);if(release_valid) $fatal(1,"early release before DMA drain");
   dma_drained=1;wait(release_valid);repeat(5) @(negedge clk);
   if(!failed || !release_valid || frame_ready) $fatal(1,"failed release hold");
   release_ready=1;@(negedge clk);release_ready=0;cancel=0;byte_valid=0;
  end
 endtask
 initial begin
  repeat(5) @(negedge clk);rst_n=1;
  begin_frame();wait(byte_ready);byte_valid=1;
  for(i=0;i<1500;i=i+1) begin do @(negedge clk);while(!byte_ready);byte_data=i;end
  wait(tx_en);@(negedge clk);cancel=1;release_frame();
  if(failed_frames!=1) $fatal(1,"cancel not counted");
  begin_frame();wait(dma_cancel);release_frame();if(failed_frames!=2) $fatal(1,"timeout not counted");
  begin_frame();link_up=0;wait(dma_cancel);release_frame();
  if(frame_ready) $fatal(1,"admitted while link down");link_up=1;
  begin_frame();if(dut.saved_epoch!=17 || dut.saved_frame!=23) $fatal(1,"network reconnect changed source");
  cancel=1;release_frame();
  if(complete_frames!=0 || failed_frames!=4) $fatal(1,"failure accounting");
  $display("NETWORK_CANCEL_PASS failed_frames=%0d",failed_frames);$finish;
 end
 initial begin #1000000;$fatal(1,"cancel test timeout");end
endmodule
