// Purpose: coherent held-data handshake from PCLK to HDMI pixel clock. Never
// treat separately synchronized live counters as an atomic measurement.
module mini_diag_snapshot(input wire src_clk,src_reset_n,dst_clk,dst_reset_n,
 input wire [159:0] source,output reg [159:0] snapshot);
 reg [159:0] held;
 reg req,ack;
 (* syn_preserve=1 *) reg ack_meta,ack_sync,req_meta,req_sync,req_delay;
 (* syn_preserve=1 *) reg [159:0] data_meta,data_sync;
 always @(posedge src_clk or negedge src_reset_n)
  if(!src_reset_n)begin ack_meta<=0;ack_sync<=0;req<=0;held<=0;end
  else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   if(req==ack_sync)begin held<=source;req<=~req;end
  end
 always @(posedge dst_clk or negedge dst_reset_n)
  if(!dst_reset_n)begin
   req_meta<=0;req_sync<=0;req_delay<=0;data_meta<=0;data_sync<=0;ack<=0;snapshot<=0;
  end else begin
   req_meta<=req;req_sync<=req_meta;req_delay<=req_sync;
   data_meta<=held;data_sync<=data_meta;
   // Extra request stage ensures the bounded data bus has settled before publication.
   if(req_delay!=ack)begin snapshot<=data_sync;ack<=req_delay;end
  end
endmodule
