`timescale 1ns/1ps
// A5 action 4 clears retained history; retired C4 action 3 returns code 6. The most recently accepted
// (outer request_seq, action) is an exact retry key both before and after apply.
// ACK means queued; only a source capture boundary emits the actual clear.
module frame_runtime_actions(
 input clk,rst_n,input submit_valid,input [15:0] action,request_seq,
 output reg [7:0] submit_code,input capture_boundary,input [63:0] epoch,frame_id,
 output clear_motion,clear_history,output reg [319:0] status_extension
);
 reg pending,have_last;reg [15:0] held_action,held_sequence,last_action,last_sequence;
 reg [7:0] applied_action;reg [15:0] applied_sequence;reg [63:0] applied_epoch,applied_frame;
 wire duplicate=have_last && request_seq==last_sequence && action==last_action;
 // Combinational boundary pulses reach consumers on the same capture edge,
 // before the later source_start initializes the first new observation.
 assign clear_motion=1'b0;
 assign clear_history=capture_boundary && pending && held_action==4;
 always @*begin
  submit_code=(action!=4)?8'd6:
   (have_last && request_seq==last_sequence)?(action==last_action?8'd0:8'd11):pending?8'd4:8'd0;
  status_extension=0;
  status_extension[0]=pending && held_action==3;status_extension[1]=pending && held_action==4;
  status_extension[15:8]=applied_action;
  status_extension[64+:64]=applied_epoch;status_extension[128+:64]=applied_frame;
  status_extension[192+:16]=applied_sequence;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin pending<=0;have_last<=0;held_action<=0;held_sequence<=0;last_action<=0;last_sequence<=0;
   applied_action<=0;applied_sequence<=0;applied_epoch<=0;applied_frame<=0;end
  else begin
   if(submit_valid && submit_code==0 && !duplicate)begin
    pending<=1;held_action<=action;held_sequence<=request_seq;
    have_last<=1;last_action<=action;last_sequence<=request_seq;
   end
   if(capture_boundary && pending)begin
    pending<=0;applied_action<=held_action[7:0];applied_sequence<=held_sequence;
    applied_epoch<=epoch;applied_frame<=frame_id;
   end
  end
 end
endmodule
