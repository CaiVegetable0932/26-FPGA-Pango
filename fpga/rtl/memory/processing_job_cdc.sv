`timescale 1ns/1ps
// Single outstanding bundled-data mailbox. The scheduler owns and holds
// source_job from acceptance UNTIL source_done. A destination-domain snapshot
// is captured after request synchronization, BEFORE processing_valid: payload
// comparisons/readiness must never control processing logic across domains.
// The processing result remains held after done until the next accepted job;
// its source-domain snapshot is captured before the completion pulse is exposed.
// Completion is legal only after every associated native read/write drains.
// Both domains and the native controller require common reset assertion.
module processing_job_cdc #(parameter JOB_BITS=1358,RESULT_BITS=1)(
 input source_clk,source_rst_n,source_valid,output source_ready,
 input [JOB_BITS-1:0] source_job,output reg source_done,source_failed,
 input processing_clk,processing_rst_n,output processing_valid,
 input processing_ready,(* syn_allow_retiming=0 *) output reg [JOB_BITS-1:0] processing_job,
 input processing_done,processing_failed,
 input [RESULT_BITS-1:0] processing_result,
 (* syn_allow_retiming=0 *) output reg [RESULT_BITS-1:0] source_result
);
 localparam S_IDLE=0,S_WAIT=1,S_CAPTURED=2;
 localparam P_IDLE=0,P_OFFER=1,P_RUN=2,P_ACK=3;
 reg [1:0] source_state,processing_state;
 reg request_toggle,response_toggle,free_toggle,failed_held;
 (* syn_preserve=1 *) reg request_meta,request_sync;
 (* syn_preserve=1 *) reg response_meta,response_sync,free_meta,free_sync;
 assign source_ready=source_state==S_IDLE;
 assign processing_valid=processing_state==P_OFFER;
 // No reset on the wide payload: P_OFFER cannot be entered before this capture.
 // ADS guide sections 5.1/5.15: forbid retiming of the data capture, but permit
 // constant/dead fields to propagate away. Whole-vector syn_preserve would
 // retain constant dimensions/disabled features and revive downstream logic.
 // Only surviving first-hop captures get CDC exceptions, never downstream logic.
 always @(posedge processing_clk)begin
  if(processing_rst_n && processing_state==P_IDLE && request_sync!=response_toggle)
   processing_job<=source_job;
 end
 always @(posedge source_clk or negedge source_rst_n)begin
  if(!source_rst_n)begin
   source_state<=S_IDLE;request_toggle<=0;free_toggle<=0;
   response_meta<=0;response_sync<=0;source_done<=0;source_failed<=0;source_result<=0;
  end else begin
   response_meta<=response_toggle;response_sync<=response_meta;source_done<=0;
   case(source_state)
    S_IDLE:if(source_valid)begin
     request_toggle<=!request_toggle;source_failed<=0;source_state<=S_WAIT;
    end
    // Capture held failure and result fields before exposing completion. The
    // scheduler can then retire all source/result references on its own clock.
    S_WAIT:if(response_sync==request_toggle)begin
     source_failed<=failed_held;source_result<=processing_result;source_state<=S_CAPTURED;
    end
    S_CAPTURED:begin
     source_done<=1;free_toggle<=request_toggle;source_state<=S_IDLE;
    end
   endcase
  end
 end
 always @(posedge processing_clk or negedge processing_rst_n)begin
  if(!processing_rst_n)begin
   processing_state<=P_IDLE;request_meta<=0;request_sync<=0;
   free_meta<=0;free_sync<=0;response_toggle<=0;failed_held<=0;
  end else begin
   request_meta<=request_toggle;request_sync<=request_meta;
   free_meta<=free_toggle;free_sync<=free_meta;
   case(processing_state)
    P_IDLE:if(request_sync!=response_toggle)processing_state<=P_OFFER;
    P_OFFER:if(processing_ready)begin
     if(processing_done)begin
      failed_held<=processing_failed;response_toggle<=request_sync;processing_state<=P_ACK;
     end else processing_state<=P_RUN;
    end
    P_RUN:if(processing_done)begin
     failed_held<=processing_failed;response_toggle<=request_sync;processing_state<=P_ACK;
    end
    P_ACK:if(free_sync==response_toggle)processing_state<=P_IDLE;
   endcase
  end
 end
endmodule
