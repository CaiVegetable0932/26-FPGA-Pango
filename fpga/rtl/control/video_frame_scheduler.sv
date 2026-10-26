`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: DDR-domain continuous ownership scheduler. Capture, geometry and
// RAW export progress independently; no frame is sealed before its writer's
// verified completion. Slot/generation and full source metadata are retained
// until the owning consumer explicitly drains and releases the reference.
module video_frame_scheduler(
 input clk,rst_n,fabric_ready,
 input [3*RSP_BITS-1:0] response,output [3*CMD_BITS-1:0] command,
 input capture_valid,output capture_ready,input [META_BITS-1:0] capture_metadata,
 // Internal history pins one previous S1; it never owns a network/export slot.
 input history_capture_enable,history_clear,
 output reg history_valid,output reg [1:0] history_slot,
 output reg [31:0] history_gen,history_base,history_skipped,
 output [META_BITS-1:0] history_metadata,
 input capture_end,input capture_isp_legal,capture_raw_legal,
 input [63:0] capture_last,input [31:0] capture_errors,
 input capture_queues_drained,output reg capture_complete,
 output capture_start,output reg capture_isp,capture_raw,
 output reg [31:0] capture_src_base,capture_src_gen,capture_raw_base,capture_raw_gen,
 output reg [1:0] capture_src_slot,capture_raw_slot,
 input isp_done,isp_failed,raw_done,raw_failed,
 output geometry_valid,input geometry_ready,geometry_done,geometry_failed,
 output reg [31:0] geometry_source_base,geometry_source_gen,geometry_result_base,geometry_result_gen,
 output reg [1:0] geometry_source_slot,geometry_result_slot,
 output [META_BITS-1:0] geometry_metadata,
 input raw_export_ready,output raw_export_valid,input raw_export_release,output raw_export_release_ready,
 output [META_BITS-1:0] raw_export_metadata,
 output reg [31:0] raw_export_base,raw_export_gen,output reg [1:0] raw_export_slot,
 // Display adapter acquires a pending reference ahead of a pixel boundary.
 // Its immutable offer owns DISPLAY from that edge until the later drain ACK.
 input display_request,output reg display_offer_valid,input display_offer_ready,
 output [META_BITS-1:0] display_metadata,
 output reg [31:0] display_base,display_gen,output reg [1:0] display_slot,
 input display_release,input [1:0] display_release_slot,input [31:0] display_release_gen,
 output display_release_ready,
 output reg [31:0] captured_frames,dropped_capture_frames,processed_frames,failed_processing_frames
);
 localparam C_IDLE=0,C_START=1,C_RUN=2,C_SEAL=3,C_DRAIN=4;
 localparam G_IDLE=0,G_ALLOC=1,G_START=2,G_RUN=3,G_SEAL=4,G_RELEASE=5,G_TAG=6,G_HISTORY_RELEASE=7,G_HISTORY_ACQUIRE=8;
 reg [2:0] capture_state;reg [3:0] geometry_state;
 reg end_seen,isp_finished,raw_finished,isp_bad,raw_bad;
 reg [63:0] end_last;reg [31:0] end_errors;
 reg [META_BITS-1:0] capture_saved,geometry_saved,raw_saved,display_saved;
 reg export_held;
 // Pending claims are recorded at allocation so later policy changes cannot
 // leak a HISTORY bit. An acquired old source stays pinned until job drain.
 reg [2:0] history_claim;
 reg history_held,history_discard;
 reg [META_BITS-1:0] history_saved;
 frame_meta_t hm,history_candidate;
 assign history_metadata=history_saved;
 assign hm=history_saved;
 assign history_candidate=sr.acquire_meta[HISTORY*META_BITS+:META_BITS];
 wire history_on=history_capture_enable===1'b1;
 wire history_flush=history_clear===1'b1;
 wire history_idle_release=geometry_state==G_IDLE && history_held &&
  (history_flush || !history_on || (capture_valid && !sr.alloc_ready));
 wire current_history_claim=history_claim[geometry_source_slot];
 wire retain_current=current_history_claim && !history_discard && history_on && !history_flush && !geometry_failed;

 wire [2:0] src_occupied,dst_occupied,raw_occupied;
 assign src_occupied=sr.occupied,dst_occupied=dr.occupied,raw_occupied=rr.occupied;
 frame_rsp_t sr,dr,rr;
 frame_cmd_t sc,dc,rc;
 frame_meta_t cm,rm,gm;
 assign sr=response[SRC*RSP_BITS+:RSP_BITS];
 assign dr=response[DST*RSP_BITS+:RSP_BITS];
 assign rr=response[RAW*RSP_BITS+:RSP_BITS];
 assign capture_ready=capture_state==C_IDLE && fabric_ready;
 assign capture_start=capture_state==C_START;
 assign geometry_valid=geometry_state==G_START;
 assign geometry_metadata=geometry_saved,raw_export_metadata=raw_saved,display_metadata=display_saved;
 assign raw_export_valid=export_held;
 assign raw_export_release_ready=rc.release_mask[NETWORK] && rr.release_ok[NETWORK];
 assign display_release_ready=dc.release_mask[DISPLAY] && dr.release_ok[DISPLAY];
 assign command={rc,dc,sc};

 // Separate operation lanes let an arriving capture allocate while an older
 // geometry job releases SRC. Metadata layouts/strides are explicit per bank.
 always @* begin
  sc='0;dc='0;rc='0;
  cm=capture_metadata;cm.stride=6144;cm.format=2;cm.stage=1;
  rm=cm;rm.stride=2048;rm.format=1;rm.stage=0;
  gm=geometry_saved;gm.stage=gm.enhancement_stage==2 ? 3:2;
  sc.meta=cm;rc.meta=rm;dc.meta=gm;
  // The primary PROCESS, DISPLAY and NETWORK readers are independent;
  // HISTORY is a separate internal S1 reference governed below.
  sc.consumers={history_on,3'b001};rc.consumers=4'b0100;dc.consumers=4'b0010;
  if(capture_valid && capture_ready)begin sc.alloc=1;rc.alloc=1;end
  if(capture_state==C_SEAL)begin
   // A cancelled write can already invalidate/free its producer slot at the
   // transport fence. Do not send a stale seal after that automatic cleanup.
   sc.seal=capture_isp && !isp_bad;sc.seal_slot=capture_src_slot;sc.seal_gen=capture_src_gen;
   sc.cancel=capture_isp && isp_bad && src_occupied[capture_src_slot];sc.cancel_slot=capture_src_slot;sc.cancel_gen=capture_src_gen;
   sc.legal=!isp_bad;sc.capture_last=end_last;sc.frame_errors=isp_bad ? (end_errors|1):0;
   rc.seal=capture_raw && !raw_bad;rc.seal_slot=capture_raw_slot;rc.seal_gen=capture_raw_gen;
   rc.cancel=capture_raw && raw_bad && raw_occupied[capture_raw_slot];rc.cancel_slot=capture_raw_slot;rc.cancel_gen=capture_raw_gen;
   rc.legal=!raw_bad;rc.capture_last=end_last;rc.frame_errors=raw_bad ? (end_errors|1):0;
  end
  if(geometry_state==G_IDLE && fabric_ready && !history_idle_release)sc.acquire[PROCESS]=1;
  if(geometry_state==G_ALLOC)dc.alloc=1;
  if(geometry_state==G_SEAL)begin
   dc.seal=!geometry_failed;dc.seal_slot=geometry_result_slot;dc.seal_gen=geometry_result_gen;
   dc.cancel=geometry_failed && dst_occupied[geometry_result_slot];dc.cancel_slot=geometry_result_slot;dc.cancel_gen=geometry_result_gen;
   dc.legal=!geometry_failed;dc.capture_last=gm.capture_last;
   dc.frame_errors=geometry_failed ? 32'h00010000:0;
  end
  if(geometry_state==G_RELEASE)begin
   sc.release_mask[PROCESS]=1;sc.release_slots={4'd0,geometry_source_slot};
   sc.release_gens={64'd0,geometry_source_gen};

  end
  // Only release the previous source after all geometry reads drained. While
  // idle, pressure/disable may retire it early to restore capture capacity.
  if((geometry_state==G_HISTORY_RELEASE || history_idle_release) && history_held)begin
   sc.release_mask[HISTORY]=1;sc.release_slots={history_slot,6'd0};
   sc.release_gens={history_gen,96'd0};
  end
  if(geometry_state==G_HISTORY_ACQUIRE && current_history_claim)begin
   if(retain_current)sc.acquire[HISTORY]=1;
   else begin
    sc.skip_mask[HISTORY]=1;sc.release_slots={geometry_source_slot,6'd0};
    sc.release_gens={geometry_source_gen,96'd0};
   end
  end
  if(!export_held && raw_export_ready && fabric_ready)rc.acquire[NETWORK]=1;
  if(export_held && raw_export_release)begin
   rc.release_mask[NETWORK]=1;rc.release_slots={raw_export_slot,4'd0};
   rc.release_gens={raw_export_gen,64'd0};
  end
  if(display_request && !display_offer_valid && fabric_ready)dc.acquire[DISPLAY]=1;
  if(display_release)begin
   dc.release_mask[DISPLAY]=1;dc.release_slots={2'd0,display_release_slot,2'd0};
   dc.release_gens={32'd0,display_release_gen,32'd0};
  end
 end

 // Completion pulses are retained independently: one writer can finish much
 // earlier, and bad/truncated input still waits for both cancellation drains.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   capture_state<=C_IDLE;geometry_state<=G_IDLE;capture_isp<=0;capture_raw<=0;capture_complete<=0;
   end_seen<=0;isp_finished<=0;raw_finished<=0;isp_bad<=0;raw_bad<=0;end_last<=0;end_errors<=0;
   capture_saved<=0;geometry_saved<=0;raw_saved<=0;display_saved<=0;export_held<=0;display_offer_valid<=0;
   capture_src_base<=0;capture_src_gen<=0;capture_raw_base<=0;capture_raw_gen<=0;capture_src_slot<=0;capture_raw_slot<=0;
   geometry_source_base<=0;geometry_source_gen<=0;geometry_result_base<=0;geometry_result_gen<=0;
   geometry_source_slot<=0;geometry_result_slot<=0;raw_export_base<=0;raw_export_gen<=0;raw_export_slot<=0;
   display_base<=0;display_gen<=0;display_slot<=0;
   history_claim<=0;history_held<=0;history_valid<=0;history_discard<=0;
   history_slot<=0;history_gen<=0;history_base<=0;history_saved<=0;history_skipped<=0;
   captured_frames<=0;dropped_capture_frames<=0;processed_frames<=0;failed_processing_frames<=0;
  end else begin
   capture_complete<=0;
   // A clear during processing invalidates eligibility immediately but the
   // physical old-source reference remains pinned until G_HISTORY_RELEASE.
   if(history_flush || !history_on)begin history_valid<=0;history_discard<=1;end
   if(history_idle_release && sr.release_ok[HISTORY])begin
    history_held<=0;history_valid<=0;history_skipped<=history_skipped+1'b1;
   end
   if(capture_valid && capture_ready)begin
    if(sr.alloc_ready)history_claim[sr.alloc_slot]<=history_on;
    capture_saved<=capture_metadata;capture_isp<=sr.alloc_ready;capture_raw<=rr.alloc_ready;
    capture_src_base<=sr.alloc_base;capture_src_gen<=sr.alloc_gen;capture_src_slot<=sr.alloc_slot;
    capture_raw_base<=rr.alloc_base;capture_raw_gen<=rr.alloc_gen;capture_raw_slot<=rr.alloc_slot;
    end_seen<=0;isp_finished<=!sr.alloc_ready;raw_finished<=!rr.alloc_ready;
    isp_bad<=!sr.alloc_ready;raw_bad<=!rr.alloc_ready;end_errors<=0;
    capture_state<=C_START;
    if(!sr.alloc_ready)dropped_capture_frames<=dropped_capture_frames+1'b1;
   end
   if(capture_state==C_START)capture_state<=C_RUN;
   if(capture_state==C_RUN)begin
    if(capture_end)begin end_seen<=1;end_last<=capture_last;end_errors<=capture_errors;
     if(!capture_isp_legal)isp_bad<=1;if(!capture_raw_legal)raw_bad<=1;end
    if(isp_done)begin isp_finished<=1;if(isp_failed)isp_bad<=1;end
    if(raw_done)begin raw_finished<=1;if(raw_failed)raw_bad<=1;end
    if(end_seen && isp_finished && raw_finished)capture_state<=C_SEAL;
   end
   if(capture_state==C_SEAL &&
     (!capture_isp || (isp_bad ? (!src_occupied[capture_src_slot] || sr.cancel_ok) : sr.seal_ok)) &&
     (!capture_raw || (raw_bad ? (!raw_occupied[capture_raw_slot] || rr.cancel_ok) : rr.seal_ok)))begin
    if(capture_isp && !isp_bad)captured_frames<=captured_frames+1'b1;
    capture_state<=C_DRAIN;
   end
   if(capture_state==C_DRAIN && capture_queues_drained)begin capture_complete<=1;capture_state<=C_IDLE;end
   case(geometry_state)
    G_IDLE:if(sr.acquire_ok[PROCESS])begin
     geometry_source_slot<=sr.acquire_slots[PROCESS*2+:2];geometry_source_gen<=sr.acquire_gens[PROCESS*32+:32];
     geometry_source_base<={7'd0,sr.acquire_slots[PROCESS*2+:2],23'd0};
     geometry_saved<=sr.acquire_meta[PROCESS*META_BITS+:META_BITS];geometry_state<=G_TAG;
    end
    G_TAG:begin
     // Only consecutive sources in one configuration can supply historical
     // pixels; confidence/motion checks remain the processing block's job.
     history_valid<=history_held && history_on && !history_flush &&
      hm.epoch==gm.epoch && hm.frame_id+64'd1==gm.frame_id &&
      hm.width==gm.width && hm.height==gm.height && hm.isp_version==gm.isp_version &&
      hm.enhancement_version==gm.enhancement_version && hm.calibration_entity==gm.calibration_entity;
     history_discard<=!history_on || history_flush;
     geometry_state<=G_ALLOC;
    end
    G_ALLOC:if(dr.alloc_ready)begin geometry_result_base<=dr.alloc_base;geometry_result_gen<=dr.alloc_gen;
     geometry_result_slot<=dr.alloc_slot;geometry_state<=G_START;end
    G_START:if(geometry_ready)geometry_state<=G_RUN;
    G_RUN:if(geometry_done)begin
     geometry_state<=G_SEAL;if(geometry_failed)failed_processing_frames<=failed_processing_frames+1'b1;
     else processed_frames<=processed_frames+1'b1;
    end
    G_SEAL:if(geometry_failed ? (!dst_occupied[geometry_result_slot] || dr.cancel_ok) : dr.seal_ok)geometry_state<=G_HISTORY_RELEASE;
    G_HISTORY_RELEASE:begin
     if(!history_held || sr.release_ok[HISTORY])begin
      history_held<=0;history_valid<=0;geometry_state<=G_HISTORY_ACQUIRE;
     end
    end
    G_HISTORY_ACQUIRE:begin
     if(!current_history_claim)geometry_state<=G_RELEASE;
     else if(sc.skip_mask[HISTORY] && sr.skip_ok[HISTORY])begin
      history_claim[geometry_source_slot]<=0;history_skipped<=history_skipped+1'b1;geometry_state<=G_RELEASE;
     end else if(sc.acquire[HISTORY] && sr.acquire_ok[HISTORY])begin
      history_held<=1;history_slot<=sr.acquire_slots[HISTORY*2+:2];history_gen<=sr.acquire_gens[HISTORY*32+:32];
      history_base<={7'd0,sr.acquire_slots[HISTORY*2+:2],23'd0};history_saved<=history_candidate;
      if(sr.acquire_slots[HISTORY*2+:2]==geometry_source_slot && sr.acquire_gens[HISTORY*32+:32]==geometry_source_gen &&
         history_candidate.epoch==gm.epoch && history_candidate.frame_id==gm.frame_id)begin
       history_claim[geometry_source_slot]<=0;geometry_state<=G_RELEASE;
      end else begin
       // Defensive FIFO cleanup never aliases an unexpected old source.
       history_skipped<=history_skipped+1'b1;geometry_state<=G_HISTORY_RELEASE;
      end
     end
    end
    G_RELEASE:if(sr.release_ok[PROCESS])begin
     geometry_state<=G_IDLE;
    end
   endcase
   if(rc.acquire[NETWORK] && rr.acquire_ok[NETWORK])begin
    export_held<=1;raw_export_slot<=rr.acquire_slots[NETWORK*2+:2];raw_export_gen<=rr.acquire_gens[NETWORK*32+:32];
    raw_export_base<=32'h03000000+{8'd0,rr.acquire_slots[NETWORK*2+:2],22'd0};raw_saved<=rr.acquire_meta[NETWORK*META_BITS+:META_BITS];
   end
   if(rc.release_mask[NETWORK] && rr.release_ok[NETWORK])export_held<=0;
   if(dc.acquire[DISPLAY] && dr.acquire_ok[DISPLAY])begin
    display_offer_valid<=1;display_slot<=dr.acquire_slots[DISPLAY*2+:2];display_gen<=dr.acquire_gens[DISPLAY*32+:32];
    display_base<=32'h01800000+{7'd0,dr.acquire_slots[DISPLAY*2+:2],23'd0};display_saved<=dr.acquire_meta[DISPLAY*META_BITS+:META_BITS];
   end
   if(display_offer_valid && display_offer_ready)display_offer_valid<=0;
  end
 end
endmodule
