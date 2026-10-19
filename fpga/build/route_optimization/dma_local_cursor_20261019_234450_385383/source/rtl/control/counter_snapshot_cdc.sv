`timescale 1ns/1ps
// Atomic whole-bus snapshot with toggle handshake. Source freezes ALL counters
// on one source edge, holds bus until a later request, ACK crosses 2FF, then
// destination captures the held bus once and retains it until consumption.
// Both resets assert together, release synchronously in their own domains.
// Integration must constrain the held bus settling path and synchronizer stages;
// this generic RTL alone is not a post-PnR CDC sign-off or free-running bus sync.
module counter_snapshot_cdc #(parameter BITS=256)(
 input src_clk,input src_rst_n,input [BITS-1:0] counters,
 input dst_clk,input dst_rst_n,input request,output request_ready,
 output reg snapshot_valid,input snapshot_ready,output reg [BITS-1:0] snapshot
);
 reg request_toggle,ack_toggle;
 reg req_meta,req_sync,ack_meta,ack_sync,busy;
 reg [BITS-1:0] held;
 assign request_ready=!busy && !snapshot_valid;
 always @(posedge src_clk or negedge src_rst_n) begin
  if(!src_rst_n) begin req_meta<=0;req_sync<=0;ack_toggle<=0;held<=0;end
  else begin
   req_meta<=request_toggle;req_sync<=req_meta;
   if(req_sync!=ack_toggle) begin held<=counters;ack_toggle<=req_sync;end
  end
 end
 always @(posedge dst_clk or negedge dst_rst_n) begin
  if(!dst_rst_n) begin request_toggle<=0;ack_meta<=0;ack_sync<=0;busy<=0;snapshot_valid<=0;snapshot<=0;end
  else begin
   ack_meta<=ack_toggle;ack_sync<=ack_meta;
   if(snapshot_valid && snapshot_ready) snapshot_valid<=0;
   if(request && request_ready) begin request_toggle<=!request_toggle;busy<=1;end
   if(busy && ack_sync==request_toggle) begin snapshot<=held;snapshot_valid<=1;busy<=0;end
  end
 end
endmodule
