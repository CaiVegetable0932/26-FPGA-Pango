`timescale 1ns/1ps
// Purpose: bounded, frame-atomic ON/OFF control. OFF selects an explicit
// normalized reference view, retaining the current lens parameters. A retry
// of the last accepted sequence AND all payload bytes has no side effects.
// The caller stores capture_coefficients/control_version in the admitted SRC
// slot; downstream jobs must never use this module's live selection bus.
module affine_frame_control(
 input clk,rst_n,
 input submit_valid,input [15:0] submit_sequence,input [95:0] submit_payload,
 output reg [7:0] submit_code,
 input other_pending,input [31:0] geometry_version,
 input [447:0] capture_geometry,input [191:0] reference_coefficients,
 input capture_boundary,input [63:0] capture_epoch,capture_frame,
 output [447:0] capture_coefficients,output capture_enable,
 output [31:0] capture_control_version,
 output reg pending,output reg applied_enable,output requested_enable,
 output reg [31:0] control_version,output [31:0] requested_version,
 output reg [63:0] applied_epoch,applied_frame,
 output reg [191:0] applied_coefficients
);
 reg pending_enable,last_valid;
 reg [31:0] pending_version;
 reg [15:0] last_sequence;
 reg [95:0] last_payload;
 wire duplicate=last_valid && submit_sequence==last_sequence && submit_payload==last_payload;
 wire same_sequence=last_valid && submit_sequence==last_sequence;
 assign requested_enable=pending?pending_enable:applied_enable;
 assign requested_version=pending?pending_version:control_version;
 assign capture_enable=requested_enable;
 assign capture_control_version=requested_version;
 assign capture_coefficients={capture_geometry[447:192],
                             capture_enable?capture_geometry[191:0]:reference_coefficients};
 // Validation and arbitration precede the request pulse. An ACK means queued;
 // applied_* changes only at the next admitted source capture, including OFF.
 always @*begin
  submit_code=0;
  if(duplicate)submit_code=0;
  else if(same_sequence || submit_payload[31:8]!=0 || submit_payload[7:0]>1 ||
          submit_payload[63:32]==0 || submit_payload[63] ||
          submit_payload[63:32]<=control_version ||
          submit_payload[95:64]!=geometry_version || geometry_version==0)
   submit_code=11;
  else if(pending || other_pending)submit_code=4;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending<=0;applied_enable<=0;pending_enable<=0;control_version<=0;
   pending_version<=0;last_valid<=0;last_sequence<=0;last_payload<=0;
   applied_epoch<=0;applied_frame<=0;applied_coefficients<=0;
  end else begin
   if(submit_valid && submit_code==0 && !duplicate)begin
    pending<=1;pending_enable<=submit_payload[0];pending_version<=submit_payload[63:32];
    last_valid<=1;last_sequence<=submit_sequence;last_payload<=submit_payload;
   end
   if(capture_boundary)begin
    // Same-edge new requests remain queued for the following source. Existing
    // pending requests are sampled identically by this block and the SRC slot.
    if(pending)begin
     applied_enable<=pending_enable;control_version<=pending_version;pending<=0;
    end
    applied_epoch<=capture_epoch;applied_frame<=capture_frame;
    applied_coefficients<=capture_coefficients[191:0];
   end
  end
 end
endmodule
