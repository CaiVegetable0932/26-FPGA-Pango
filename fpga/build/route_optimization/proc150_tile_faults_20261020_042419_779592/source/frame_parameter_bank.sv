`timescale 1ns/1ps
// Whole validated parameter entities commit atomically on a capture boundary.
// Validator is external (model/range/CRC/conversion), not an ACK bypass. One
// pending commit is bounded; newer writes stall rather than corrupt its entity.
// Applied versions/handles are frozen into each frame's descriptor by section 03.
// Geometry consumers use those immutable handles, not the live active bus.
module frame_parameter_bank #(parameter ENTITY_BITS=512)(
 input clk,input rst_n,
 input submit_valid,output submit_ready,input entity_validated,
 input [ENTITY_BITS-1:0] entity,input [31:0] version,entity_id,
 output reg received,validated,rejected,
 input capture_boundary,input [63:0] epoch,frame_id,
 output reg [ENTITY_BITS-1:0] active_entity,
 output reg [31:0] active_version,active_entity_id,
 output [ENTITY_BITS-1:0] capture_entity,
 output [31:0] capture_version,capture_entity_id,
 output reg applied,input applied_ready,
 output reg [63:0] applied_epoch,applied_frame,
 output pending
);
 reg waiting;reg [ENTITY_BITS-1:0] shadow;
 reg [31:0] shadow_version,shadow_id;
 assign pending=waiting;
 assign submit_ready=!waiting && !applied;
 // A frame descriptor samples capture_* on the SAME capture edge as commit.
 // Sampling active_* there would see the old nonblocking-register version.
 assign capture_entity=(waiting && !applied)?shadow:active_entity;
 assign capture_version=(waiting && !applied)?shadow_version:active_version;
 assign capture_entity_id=(waiting && !applied)?shadow_id:active_entity_id;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   waiting<=0;shadow<=0;shadow_version<=0;shadow_id<=0;active_entity<=0;
   active_version<=0;active_entity_id<=0;applied<=0;applied_epoch<=0;applied_frame<=0;
   received<=0;validated<=0;rejected<=0;
  end else begin
   received<=0;validated<=0;rejected<=0;
   if(applied && applied_ready) applied<=0;
   if(submit_valid && submit_ready) begin
    received<=1;
    if(!entity_validated || version<=active_version || entity_id==0) rejected<=1;
    else begin shadow<=entity;shadow_version<=version;shadow_id<=entity_id;waiting<=1;validated<=1;end
   end
   if(capture_boundary && waiting && !applied) begin
    active_entity<=shadow;active_version<=shadow_version;active_entity_id<=shadow_id;
    applied<=1;applied_epoch<=epoch;applied_frame<=frame_id;waiting<=0;
   end
  end
 end
endmodule
