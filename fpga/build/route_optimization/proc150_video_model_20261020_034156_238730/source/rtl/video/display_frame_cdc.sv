`timescale 1ns/1ps
// Purpose: atomic DDR-owned frame offers to the HDMI pixel domain, with an
// independent return mailbox for drained old references. Pixel release_ready
// reserves the mailbox; the old DDR reference remains owned until memory ACK.
// This permits an atomic old->new switch at a single pixel frame boundary.
module display_frame_cdc(
 input memory_clk,memory_rst_n,output memory_request,
 input memory_offer_valid,output memory_offer_ready,
 input [31:0] memory_base,memory_generation,input [1:0] memory_slot,input [63:0] memory_epoch,memory_id,
 output memory_release_valid,input memory_release_ready,
 output reg [1:0] memory_release_slot,output reg [31:0] memory_release_generation,
 input pixel_clk,pixel_rst_n,output pixel_offer_valid,input pixel_offer_ready,
 output [31:0] pixel_base,pixel_generation,output [1:0] pixel_slot,output [63:0] pixel_epoch,pixel_id,
 input pixel_release_valid,output pixel_release_ready,input [1:0] pixel_release_slot,input [31:0] pixel_release_generation
);
 reg offer_toggle,offer_ack,release_toggle,release_ack,release_pending;
 reg [193:0] offer_held;reg [33:0] release_held;
 reg [193:0] offer_local;reg offer_pending;
 (* syn_preserve=1 *) reg offer_meta,offer_sync,offer_ack_meta,offer_ack_sync;
 (* syn_preserve=1 *) reg release_meta,release_sync,release_ack_meta,release_ack_sync;
 assign memory_offer_ready=offer_toggle==offer_ack_sync;
 assign memory_request=memory_offer_ready;
 assign pixel_offer_valid=offer_pending;
 assign {pixel_base,pixel_generation,pixel_slot,pixel_epoch,pixel_id}=offer_local;
 assign pixel_release_ready=release_toggle==release_ack_sync;
 assign memory_release_valid=release_pending;
 // Held buses never change while their request is outstanding. Two-flop
 // control synchronization plus explicit board max-delay bounds protect them.
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin offer_toggle<=0;offer_held<=0;offer_ack_meta<=0;offer_ack_sync<=0;
   release_meta<=0;release_sync<=0;release_ack<=0;release_pending<=0;memory_release_slot<=0;memory_release_generation<=0;end
  else begin
   offer_ack_meta<=offer_ack;offer_ack_sync<=offer_ack_meta;
   release_meta<=release_toggle;release_sync<=release_meta;
   if(memory_offer_valid && memory_offer_ready)begin
    offer_held<={memory_base,memory_generation,memory_slot,memory_epoch,memory_id};offer_toggle<=!offer_toggle;
   end
   // Capture the held payload after its synchronized toggle, then present
   // ordinary memory-domain registers to ownership/ready combinational logic.
   if(release_sync!=release_ack && !release_pending)begin
    {memory_release_slot,memory_release_generation}<=release_held;release_pending<=1;
   end
   if(memory_release_valid && memory_release_ready)begin release_ack<=release_sync;release_pending<=0;end
  end
 end
 always @(posedge pixel_clk or negedge pixel_rst_n)begin
  if(!pixel_rst_n)begin offer_meta<=0;offer_sync<=0;offer_ack<=0;offer_local<=0;offer_pending<=0;release_toggle<=0;release_held<=0;
   release_ack_meta<=0;release_ack_sync<=0;end
  else begin
   offer_meta<=offer_toggle;offer_sync<=offer_meta;
   release_ack_meta<=release_ack;release_ack_sync<=release_ack_meta;
   // Bound the asynchronous held bus only to this capture bank. Prefetch
   // addresses and scanout decisions use ordinary related-domain registers.
   if(offer_sync!=offer_ack && !offer_pending)begin offer_local<=offer_held;offer_pending<=1;end
   if(pixel_offer_valid && pixel_offer_ready)begin offer_ack<=offer_sync;offer_pending<=0;end
   if(pixel_release_valid && pixel_release_ready)begin
    release_held<={pixel_release_slot,pixel_release_generation};release_toggle<=!release_toggle;
   end
  end
 end
endmodule
