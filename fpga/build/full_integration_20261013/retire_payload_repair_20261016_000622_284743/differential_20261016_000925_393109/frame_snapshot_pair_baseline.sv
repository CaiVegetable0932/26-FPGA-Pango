`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: one bounded same-source S1/result snapshot, copied into two dedicated
// banks before export. Commands own source consumer SNAPSHOT and destination
// allocation/seal/cancel lanes only; the adapter owns issue/complete lanes.
// Request source handles must already have pending SNAPSHOT claims, registered
// while S1 is retained. Stage encoding is copied unchanged from upstream.
module frame_snapshot_pair_baseline #(parameter integer WAIT_CYCLES=10000000)(
 input wire clk, reset_n, fabric_ready,
 input wire request, cancel,
 input wire [1:0] source_slot, result_slot,
 input wire [31:0] source_gen, result_gen,
 output wire request_ready,
 input wire [5*RSP_BITS-1:0] response,
 output reg [5*CMD_BITS-1:0] command,
 output wire copy_valid, copy_cancel,
 input wire copy_ready, copy_done, copy_error, copy_drained,
 output wire [1:0] copy_source_slot, copy_result_slot,
 output wire [31:0] copy_source_gen, copy_result_gen,
 output wire [31:0] copy_s1_gen, copy_dst_gen,
 output frame_meta_t source_meta, result_meta,
 output wire pair_ready, busy,
 output reg failed,
 output reg [31:0] completed_pairs, failed_pairs
);
 localparam IDLE=0, ACQUIRE=1, CHECK_PAIR=2, ALLOCATE=3, JOB=4,
  COPY=5, SEAL=6, WAIT_READY=7, EXPORT=8, ABORT_DRAIN=9, CLEANUP=10;
 reg [3:0] state;
 reg [31:0] timer;
 reg [1:0] ss, rs;
 reg [31:0] sg, rg, snap_sg, snap_rg;
 reg own_s, own_r, seen_s, seen_r, alloc_s, alloc_r, started, done_seen, error_seen;
 frame_meta_t sm, rm;
 frame_cmd_t cs, cr, ds, dr;
 frame_rsp_t srsp, rrsp, dsrsp, drrsp;
 wire [3:0] source_acq=srsp.acquire_ok, result_acq=rrsp.acquire_ok;
 wire [4*META_BITS-1:0] source_bus=srsp.acquire_meta, result_bus=rrsp.acquire_meta;
 wire [2:0] snap_sready=dsrsp.ready_frames, snap_rready=drrsp.ready_frames;
 assign srsp=response[SRC*RSP_BITS+:RSP_BITS]; assign rrsp=response[DST*RSP_BITS+:RSP_BITS];
 assign dsrsp=response[SNAP_S1*RSP_BITS+:RSP_BITS]; assign drrsp=response[SNAP_RESULT*RSP_BITS+:RSP_BITS];
 assign request_ready=state==IDLE && fabric_ready && !cancel &&
  dsrsp.occupied==0 && drrsp.occupied==0;
 assign busy=state!=IDLE;
 // Purpose: pair eligibility is latched by entry to EXPORT. Releasing one
 // image must not prevent acquisition/export of the second retained image.
 assign pair_ready=state==EXPORT && fabric_ready;
 assign copy_valid=state==JOB && fabric_ready && !cancel;
 assign copy_cancel=state==ABORT_DRAIN && started;
 assign copy_source_slot=ss; assign copy_result_slot=rs;
 assign copy_source_gen=sg; assign copy_result_gen=rg;
 assign copy_s1_gen=snap_sg; assign copy_dst_gen=snap_rg;
 assign source_meta=sm; assign result_meta=rm;

 // Purpose: merge these non-transaction lanes with adapter transactions and
 // other source consumers. Network acquisitions on snapshot banks are gated by
 // pair_ready by the integration; individual READY is not a valid pair export.
 always @* begin
  cs='0; cr='0; ds='0; dr='0;
  if(fabric_ready) begin
   case(state)
    ACQUIRE: if(!cancel) begin
     cs.acquire=own_s?0:8; cs.snap_exact=1; cs.snap_slot=ss; cs.snap_gen=sg;
     cr.acquire=own_r?0:8; cr.snap_exact=1; cr.snap_slot=rs; cr.snap_gen=rg;
    end
    ALLOCATE: if(!cancel) begin
     ds.alloc=!alloc_s; ds.meta=sm; ds.consumers=4;
     dr.alloc=!alloc_r; dr.meta=rm; dr.consumers=4;
    end
    SEAL: if(!cancel) begin
     ds.seal=1; ds.seal_slot=0; ds.seal_gen=snap_sg; ds.legal=1; ds.capture_last=sm.capture_last;
     dr.seal=1; dr.seal_slot=0; dr.seal_gen=snap_rg; dr.legal=1; dr.capture_last=rm.capture_last;
     cs.release_mask=8; cs.release_slots={ss,6'b0}; cs.release_gens={sg,96'b0};
     cr.release_mask=8; cr.release_slots={rs,6'b0}; cr.release_gens={rg,96'b0};
    end
    CLEANUP: begin
     if(own_s) cs.release_mask=8; else if(!seen_s) cs.skip_mask=8;
     if(own_r) cr.release_mask=8; else if(!seen_r) cr.skip_mask=8;
     cs.release_slots={ss,6'b0}; cs.release_gens={sg,96'b0};
     cr.release_slots={rs,6'b0}; cr.release_gens={rg,96'b0};
     ds.cancel=alloc_s; ds.cancel_slot=0; ds.cancel_gen=snap_sg;
     dr.cancel=alloc_r; dr.cancel_slot=0; dr.cancel_gen=snap_rg;
    end
   endcase
  end
  command='0;
  command[SRC*CMD_BITS+:CMD_BITS]=cs; command[DST*CMD_BITS+:CMD_BITS]=cr;
  command[SNAP_S1*CMD_BITS+:CMD_BITS]=ds; command[SNAP_RESULT*CMD_BITS+:CMD_BITS]=dr;
 end
 // Purpose: early timeout/cancel drops only snapshot claims, preserving normal
 // processing/display/network owners. Once a copy starts, even failed/cancelled
 // requests hold source ownership until the adapter explicitly confirms drain.
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   state<=IDLE; timer<=0; ss<=0; rs<=0; sg<=0; rg<=0; snap_sg<=0; snap_rg<=0;
   own_s<=0; own_r<=0; seen_s<=0; seen_r<=0; alloc_s<=0; alloc_r<=0; started<=0; done_seen<=0; error_seen<=0;
   sm<='0; rm<='0; failed<=0; completed_pairs<=0; failed_pairs<=0;
  end else if(fabric_ready) begin
   failed<=0;
   if(state!=IDLE && state!=EXPORT && state!=ABORT_DRAIN && state!=CLEANUP) timer<=timer+1'b1;
   case(state)
    IDLE: if(request && request_ready) begin
     ss<=source_slot; rs<=result_slot; sg<=source_gen; rg<=result_gen;
     own_s<=0; own_r<=0; seen_s<=0; seen_r<=0; alloc_s<=0; alloc_r<=0; started<=0; done_seen<=0; error_seen<=0;
     timer<=0; state<=ACQUIRE;
    end
    ACQUIRE: begin
     if(source_acq[SNAPSHOT]) begin own_s<=1; seen_s<=1; sm<=source_bus[SNAPSHOT*META_BITS+:META_BITS]; end
     if(result_acq[SNAPSHOT]) begin own_r<=1; seen_r<=1; rm<=result_bus[SNAPSHOT*META_BITS+:META_BITS]; end
     if((own_s || source_acq[SNAPSHOT]) && (own_r || result_acq[SNAPSHOT])) state<=CHECK_PAIR;
    end
    CHECK_PAIR: begin
     if(sm.epoch==rm.epoch && sm.frame_id==rm.frame_id && sm.width==rm.width &&
        sm.height==rm.height && sm.format==2 && rm.format==2 && sm.errors==0 && rm.errors==0)
      state<=ALLOCATE;
     else state<=ABORT_DRAIN;
    end
    ALLOCATE: begin
     if(ds.alloc && dsrsp.alloc_ready) begin alloc_s<=1; snap_sg<=dsrsp.alloc_gen; end
     if(dr.alloc && drrsp.alloc_ready) begin alloc_r<=1; snap_rg<=drrsp.alloc_gen; end
     if((alloc_s || dsrsp.alloc_ready) && (alloc_r || drrsp.alloc_ready)) state<=JOB;
    end
    JOB: if(copy_valid && copy_ready) begin started<=1; state<=COPY; timer<=0; end
    COPY: begin
     if(copy_done) done_seen<=1;
     if(copy_error) error_seen<=1;
     if(copy_error || error_seen) state<=ABORT_DRAIN;
     else if((done_seen || copy_done) && copy_drained) state<=SEAL;
    end
    SEAL: begin
     if(srsp.release_ok==8) own_s<=0;
     if(rrsp.release_ok==8) own_r<=0;
     if(dsrsp.seal_ok && drrsp.seal_ok && srsp.release_ok==8 && rrsp.release_ok==8) begin
      own_s<=0; own_r<=0; started<=0; state<=WAIT_READY;
     end else state<=ABORT_DRAIN;
    end
    WAIT_READY: if(snap_sready!=0 && snap_rready!=0) begin
     completed_pairs<=completed_pairs+1'b1; state<=EXPORT;
    end
    EXPORT: begin
     if(dsrsp.occupied==0 && drrsp.occupied==0) state<=IDLE;
     // Both banks were sealed and all producer writes drained before EXPORT.
     // An occupied bank without a ready frame therefore became invalid (for
     // example, an export read error). A normally released first image has
     // occupied==0 as well and must not invalidate the still-retained second.
     // started was cleared at SEAL: cleanup needs no second copy drain pulse.
     // Bank CANCEL preserves any accepted NETWORK reference until its release.
     else if((dsrsp.occupied!=0 && snap_sready==0) ||
             (drrsp.occupied!=0 && snap_rready==0)) state<=ABORT_DRAIN;
    end
    ABORT_DRAIN: if(!started || copy_drained) state<=CLEANUP;
    CLEANUP: begin
     own_s<=0; own_r<=0; failed<=1; failed_pairs<=failed_pairs+1'b1; state<=IDLE;
    end
    default: state<=ABORT_DRAIN;
   endcase
   // Timeout never invents a drain response; failed copies may wait here until
   // the adapter's bounded cancel contract retires every accepted transaction.
   if(state!=IDLE && state!=ABORT_DRAIN && state!=CLEANUP &&
      (cancel || (state!=EXPORT && timer>=WAIT_CYCLES-1))) state<=ABORT_DRAIN;
  end
 end
endmodule
