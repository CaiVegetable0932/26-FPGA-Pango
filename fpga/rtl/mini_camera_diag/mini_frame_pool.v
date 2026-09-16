`timescale 1ns/1ps
// Purpose: own four DDR frame slots in the memory clock domain. Only completed
// DMA writes become display candidates; display-owned/latest slots are never
// allocated for capture. Requests use four-phase level handshakes across CDC.
// A new camera request may abandon an incomplete frame, but the old slot stays
// excluded until the vendor DMA acknowledges the new request at a burst boundary.
module mini_frame_pool(
 input clk, reset_n, camera_req, display_req,
 input dma_write_ack, dma_read_ack, dma_write_finish,
 output reg camera_ack, display_ack,
 output reg dma_write_req, dma_read_req,
 output reg [1:0] write_index, read_index,
 output reg display_valid,
 output reg [31:0] completed_frames, abandoned_frames
);
 (* syn_preserve=1 *) reg camera_meta,camera_sync,display_meta,display_sync;
 reg [2:0] wstate,rstate;
 reg writing,latest_valid;
 reg [1:0] latest_index;
 reg [1:0] read_locked_index;
 reg candidate_valid;
 reg [1:0] candidate;
 integer i;
 // Purpose: only single-bit request levels cross clocks; all slot indices are
 // generated here and stay stable throughout the downstream DMA handshake.
 always @(posedge clk or negedge reset_n)
  if(!reset_n) begin camera_meta<=0;camera_sync<=0;display_meta<=0;display_sync<=0;end
  else begin camera_meta<=camera_req;camera_sync<=camera_meta;
   display_meta<=display_req;display_sync<=display_meta;end
 // Purpose: keep latest completed, current display and in-flight write distinct.
 always @* begin
  candidate=0;candidate_valid=0;
  for(i=0;i<4;i=i+1)
   if(!candidate_valid && (!writing || i!=write_index) &&
      (!display_valid || i!=read_locked_index) && (rstate!=1 || i!=read_index) &&
      (!latest_valid || i!=latest_index)) begin
    candidate=i;candidate_valid=1;
   end
 end
 always @(posedge clk or negedge reset_n)
  if(!reset_n) begin
   wstate<=0;rstate<=0;writing<=0;latest_valid<=0;latest_index<=0;read_locked_index<=0;
   camera_ack<=0;display_ack<=0;dma_write_req<=0;dma_read_req<=0;
   write_index<=0;read_index<=0;display_valid<=0;completed_frames<=0;abandoned_frames<=0;
  end else begin
   // Purpose: publish only a completed DMA, never the previous VSYNC slot.
   // A completion while switching requests belongs to an abandoned old frame.
   if(wstate==0 && dma_write_finish && writing) begin
    latest_index<=write_index;latest_valid<=1;writing<=0;
    completed_frames<=completed_frames+1'b1;
   end
   case(wstate)
    0: if(camera_sync && candidate_valid) begin
     if(writing && !dma_write_finish) abandoned_frames<=abandoned_frames+1'b1;
     write_index<=candidate;writing<=0;dma_write_req<=1;wstate<=1;
    end
    1: if(dma_write_ack) begin
     dma_write_req<=0;camera_ack<=1;writing<=1;wstate<=2;
    end
    2: if(!camera_sync && !dma_write_ack) begin camera_ack<=0;wstate<=0;end
    default: wstate<=0;
   endcase
   // Purpose: before the first complete frame, acknowledge display requests but
   // issue no DDR reads. A completed slot is locked through the display frame.
   case(rstate)
    0: if(display_sync) begin
     if(latest_valid) begin read_index<=latest_index;dma_read_req<=1;rstate<=1;end
     else begin display_valid<=0;display_ack<=1;rstate<=2;end
    end
    // Purpose: release the previous display slot only after the DMA has stopped
    // its old burst and acknowledged the new slot, not when the request starts.
    1: if(dma_read_ack) begin
     dma_read_req<=0;read_locked_index<=read_index;display_valid<=1;display_ack<=1;rstate<=2;
    end
    2: if(!display_sync && !dma_read_ack) begin display_ack<=0;rstate<=0;end
    default: rstate<=0;
   endcase
  end
endmodule
