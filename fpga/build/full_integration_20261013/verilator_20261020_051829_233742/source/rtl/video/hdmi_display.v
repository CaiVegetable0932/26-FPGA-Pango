`timescale 1ns/1ps
// Purpose: formal RGB888 scanout with ordered complete-frame offers, immutable
// slot/generation/source identity, two-line prefetch and fail-black recovery.
// All ports are pixel-domain. Offer is a validated complete DST RGB888 frame
// reference; its acquire and release are atomic with the downstream adapter.
// Release is allowed only at frame boundary (or disabled/lost lock), after DMA
// done ACK and local prefetch reads drain. A missing offer repeats the same ref.
// rst_n is cold fabric reset; stream_enable/locked stop video without dropping
// in-flight DMA ownership. Neither signal is an OSERDES startup reset.
module hdmi_display #(
 parameter H_ACTIVE=1920,H_SYNC=44,H_BACK=148,H_FRONT=88,
 parameter V_ACTIVE=1080,V_SYNC=5,V_BACK=36,V_FRONT=4,STRIDE=6144
)(
 input clk,rst_n,stream_enable,locked,
 input offer_valid,output offer_ready,input [31:0] offer_base,offer_generation,
 input [1:0] offer_slot,input [63:0] offer_epoch,offer_frame_id,
 output release_valid,input release_ready,output [1:0] release_slot,
 output [31:0] release_generation,
 output frame_boundary,output reg hs,vs,de,output reg [23:0] rgb,
 output reg [11:0] x,y,output reg tag_valid,
 output reg [63:0] epoch,source_frame_id,output reg [31:0] generation,
 output reg [31:0] display_new_frames,display_repeat_frames,display_failed_frames,
 output reg [31:0] display_scan_frames,display_empty_frames,
 output reg [31:0] underflow_events,underflow_pixels,
 output [31:0] max_no_service_cycles,low_water_cycles,
 output req_valid,input req_ready,output [31:0] req_addr,
 output [4:0] req_beats,output [31:0] req_tag,
 input r_valid,output r_ready,input [255:0] r_data,input r_last,
 input done,output done_ready,input cancelled,error,input [31:0] done_tag,
 output cancel,urgent,output [1:0] ready_lines,output dma_fault
);
 wire rh,rv,rd,prepare;wire [11:0] rx,ry;
 video_raster #(.H_ACTIVE(H_ACTIVE),.H_SYNC(H_SYNC),.H_BACK(H_BACK),.H_FRONT(H_FRONT),
 .V_ACTIVE(V_ACTIVE),.V_SYNC(V_SYNC),.V_BACK(V_BACK),.V_FRONT(V_FRONT)) raster(
 .clk(clk),.rst_n(rst_n),.hs(rh),.vs(rv),.de(rd),.frame_start(frame_boundary),
 .line_prepare(prepare),.x(rx),.y(ry));
 reg held,frame_running,frame_bad,new_frame;
 reg [31:0] held_base,held_gen;
 reg [1:0] held_slot;
 reg [63:0] held_epoch,held_id;
 wire drained,pv,missing;wire [23:0] p;
 wire enabled=stream_enable && locked;
 // A release pulse is accepted atomically with a new offer at the boundary.
 // If ACK stalls, keep the old reference and repeat; never switch mid-frame.
 assign release_valid=held && drained && (!enabled || (frame_boundary && offer_valid));
 assign release_slot=held_slot;
 assign release_generation=held_gen;
 assign offer_ready=enabled && frame_boundary && drained && (!held || release_ready);
 wire acquire=offer_valid && offer_ready;
 wire start=enabled && frame_boundary && drained && (held || acquire);
 wire underflow=frame_running && !frame_bad && (missing || (rd && !pv));
 wire abort=!enabled || frame_bad || underflow || dma_fault;
 wire consume=rd && frame_running && !frame_bad && enabled;
 rgb888_line_prefetch #(.H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),.STRIDE(STRIDE)) reader(
 .clk(clk),.rst_n(rst_n),.start(start),.abort(abort),
 .base(acquire?offer_base:held_base),.generation(acquire?offer_generation:held_gen),
 .line_prepare(prepare),.scan_y(ry),.consume(consume),.line_end(rd && rx==H_ACTIVE-1),
 .pixel_valid(pv),.pixel(p),.line_missing(missing),.drained(drained),.urgent(urgent),.ready_lines(ready_lines),
 .req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),.req_beats(req_beats),.req_tag(req_tag),
 .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),
 .done(done),.done_ready(done_ready),.cancelled(cancelled),.error(error),.done_tag(done_tag),
 .cancel(cancel),.fault(dma_fault),.max_no_service_cycles(max_no_service_cycles),.low_water_cycles(low_water_cycles));
 // Purpose: one common output register aligns RGB, HS/VS/DE, coordinates and
 // source tag. DE preserves the raster even on black fallback; tag_valid marks
 // original pixels only. No OSD/marker overwrites formal effective pixels.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   held<=0;frame_running<=0;frame_bad<=0;new_frame<=0;held_base<=0;held_gen<=0;held_slot<=0;held_epoch<=0;held_id<=0;
   hs<=0;vs<=0;de<=0;rgb<=0;x<=0;y<=0;tag_valid<=0;epoch<=0;source_frame_id<=0;generation<=0;
   display_new_frames<=0;display_repeat_frames<=0;display_failed_frames<=0;
   display_scan_frames<=0;display_empty_frames<=0;underflow_events<=0;underflow_pixels<=0;
  end else begin
   hs<=rh;vs<=rv;de<=rd;x<=rx;y<=ry;
   rgb<=(consume && pv && !dma_fault)?p:24'd0;
   tag_valid<=consume && pv && !dma_fault;
   epoch<=held_epoch;source_frame_id<=held_id;generation<=held_gen;
   if(release_valid && release_ready) held<=0;
   if(acquire) begin
    held<=1;held_base<=offer_base;held_gen<=offer_generation;held_slot<=offer_slot;
    held_epoch<=offer_epoch;held_id<=offer_frame_id;
   end
   if(!enabled) begin frame_bad<=1;end
   if(underflow) begin frame_bad<=1;underflow_events<=underflow_events+1'b1;end
   if(dma_fault) frame_bad<=1;
   if(rd && held && (!frame_running || !enabled || frame_bad || !pv || dma_fault))
    underflow_pixels<=underflow_pixels+1'b1;
   // Count only fully transmitted frames; READY/processing/card counts belong
   // to their owning modules. Failed/black frames never increment good counts.
   if(rd && rx==H_ACTIVE-1 && ry==V_ACTIVE-1) begin
    display_scan_frames<=display_scan_frames+1'b1;
    // A drain that spans another field must be visible as failed/empty scanout,
    // even when no new prefetch session could start at that field boundary.
    if(!frame_running && !held) display_empty_frames<=display_empty_frames+1'b1;
    else if(!frame_running || frame_bad || underflow || !enabled || dma_fault) display_failed_frames<=display_failed_frames+1'b1;
    else if(new_frame) display_new_frames<=display_new_frames+1'b1;
    else display_repeat_frames<=display_repeat_frames+1'b1;
   end
   if(frame_boundary) begin
    frame_running<=start;frame_bad<=!start;new_frame<=acquire;
   end
  end
 end
endmodule
