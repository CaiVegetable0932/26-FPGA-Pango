`timescale 1ns/1ps
// Purpose: attach the board's actual display context CDC, DMA CDC and RGB
// scanout to the full memory-core model. This is synthetic pixel/identity
// checking, not TMDS electrical verification or physical source provenance.
module video_core_display_fixture(
 input clk,rst_n,
 output memory_request,input offer_valid,output offer_ready,
 input [31:0] base,generation,input [1:0] slot,input [63:0] epoch,frame_id,
 output release_valid,input release_ready,output [1:0] release_slot,
 output [31:0] release_generation,
 output req_valid,input req_ready,output [31:0] req_addr,req_tag,output [4:0] req_beats,
 output cancel,urgent,input r_valid,output r_ready,input [255:0] r_data,input r_last,
 input done,output done_ready,input error,cancelled,input [31:0] done_tag,
 output [31:0] new_frames,repeat_frames,failed_frames,underflow_events,underflow_pixels,
 output confirm_valid,output [63:0] confirm_epoch,confirm_frame,output [31:0] confirm_generation,
 output reg [31:0] checked_pixels=0,output dma_fault
);
 // Match the established HDMI fixture's 74.25MHz approximation (1ps
 // timescale rounding), independently of the 125MHz memory clock.
 reg pixel_clk=0;always #6.734 pixel_clk=~pixel_clk;
 wire p_offer,p_offer_ready,p_release,p_release_ready;
 wire [31:0] p_base,p_gen,p_release_gen;wire [1:0] p_slot,p_release_slot;
 wire [63:0] p_epoch,p_id;
 display_frame_cdc context_bridge(.memory_clk(clk),.memory_rst_n(rst_n),.memory_request(memory_request),
  .memory_offer_valid(offer_valid),.memory_offer_ready(offer_ready),.memory_base(base),.memory_generation(generation),.memory_slot(slot),
  .memory_epoch(epoch),.memory_id(frame_id),.memory_release_valid(release_valid),.memory_release_ready(release_ready),
  .memory_release_slot(release_slot),.memory_release_generation(release_generation),.pixel_clk(pixel_clk),.pixel_rst_n(rst_n),
  .pixel_offer_valid(p_offer),.pixel_offer_ready(p_offer_ready),.pixel_base(p_base),.pixel_generation(p_gen),.pixel_slot(p_slot),
  .pixel_epoch(p_epoch),.pixel_id(p_id),.pixel_release_valid(p_release),.pixel_release_ready(p_release_ready),
  .pixel_release_slot(p_release_slot),.pixel_release_generation(p_release_gen));
 wire p_req,p_req_ready,p_cancel,p_rvalid,p_rready,p_rlast,p_done,p_done_ready,p_error,p_cancelled,p_urgent;
 wire [31:0] p_addr,p_tag,p_done_tag;wire [4:0] p_beats;wire [255:0] p_rdata;
 reg urgent_meta,urgent_sync;
 // The same two-flop urgency crossing is used by pango_video_system.
 always @(posedge clk or negedge rst_n)if(!rst_n)begin urgent_meta<=0;urgent_sync<=0;end
  else begin urgent_meta<=p_urgent;urgent_sync<=urgent_meta;end
 assign urgent=urgent_sync;
 dma_read_cdc dma_bridge(.client_clk(pixel_clk),.client_rst_n(rst_n),.req_valid(p_req),.req_ready(p_req_ready),
  .req_addr(p_addr),.req_tag(p_tag),.req_beats(p_beats),.cancel(p_cancel),.r_valid(p_rvalid),.r_ready(p_rready),
  .r_data(p_rdata),.r_last(p_rlast),.done(p_done),.done_ready(p_done_ready),.error(p_error),.cancelled(p_cancelled),.done_tag(p_done_tag),
  .memory_clk(clk),.memory_rst_n(rst_n),.memory_req_valid(req_valid),.memory_req_ready(req_ready),.memory_req_addr(req_addr),
  .memory_req_tag(req_tag),.memory_req_beats(req_beats),.memory_cancel(cancel),.memory_r_valid(r_valid),.memory_r_ready(r_ready),
  .memory_r_data(r_data),.memory_r_last(r_last),.memory_done(done),.memory_done_ready(done_ready),
  .memory_error(error),.memory_cancelled(cancelled),.memory_done_tag(done_tag));
 wire [31:0] displayed_generation;wire confirmation_ready,confirmation_valid;
 wire [160:0] confirmation;
 counter_snapshot_cdc #(.BITS(161)) confirmation_cdc(.src_clk(pixel_clk),.src_rst_n(rst_n),
  .counters({tag_valid,displayed_epoch,displayed_id,displayed_generation}),
  .dst_clk(clk),.dst_rst_n(rst_n),.request(confirmation_ready),.request_ready(confirmation_ready),
  .snapshot_valid(confirmation_valid),.snapshot_ready(1'b1),.snapshot(confirmation));
 assign confirm_valid=confirmation_valid && confirmation[160];
 assign {confirm_epoch,confirm_frame,confirm_generation}=confirmation[159:0];
 wire de,tag_valid;wire [23:0] rgb;wire [63:0] displayed_epoch,displayed_id;
 hdmi_display display(.clk(pixel_clk),.rst_n(rst_n),.stream_enable(1'b1),.locked(1'b1),
  .offer_valid(p_offer),.offer_ready(p_offer_ready),.offer_base(p_base),.offer_generation(p_gen),.offer_slot(p_slot),
  .offer_epoch(p_epoch),.offer_frame_id(p_id),.release_valid(p_release),.release_ready(p_release_ready),
  .release_slot(p_release_slot),.release_generation(p_release_gen),.frame_boundary(),.hs(),.vs(),.de(de),.rgb(rgb),.x(),.y(),
  .tag_valid(tag_valid),.epoch(displayed_epoch),.source_frame_id(displayed_id),.generation(displayed_generation),
  .display_new_frames(new_frames),.display_repeat_frames(repeat_frames),.display_failed_frames(failed_frames),
  .display_scan_frames(),.display_empty_frames(),.underflow_events(underflow_events),.underflow_pixels(underflow_pixels),
  .max_no_service_cycles(),.low_water_cycles(),.req_valid(p_req),.req_ready(p_req_ready),.req_addr(p_addr),.req_beats(p_beats),
  .req_tag(p_tag),.r_valid(p_rvalid),.r_ready(p_rready),.r_data(p_rdata),.r_last(p_rlast),.done(p_done),.done_ready(p_done_ready),
  .cancelled(p_cancelled),.error(p_error),.done_tag(p_done_tag),.cancel(p_cancel),.urgent(p_urgent),.ready_lines(),.dma_fault(dma_fault));
 // Independent expected bytes follow the original core fixture: source 1
 // is raw grey73, source3 uses pre gamma=0.7 tone114 and source4 disables tone and returns grey91.
 // Never infer identities from display arrival order or count repeated frames
 // as newly corrected frames. Every qualified output carries its actual tag.
 reg [23:0] expected_rgb;
 reg [31:0] previous_new=0;
 always @(posedge pixel_clk)begin
  // Fail at the first real scanout error rather than waiting for a later
  // snapshot/network completion that a quarantined memory fabric cannot make.
  if(rst_n && (dma_fault || failed_frames!=0 || underflow_events!=0))
   $fatal(1,"DISPLAY_CORE early scanout failure dma=%b failed=%0d underflow=%0d",dma_fault,failed_frames,underflow_events);
  if(rst_n && new_frames!=previous_new)begin
   previous_new=new_frames;
   $display("DISPLAY_CORE_PROGRESS new=%0d repeat=%0d checked_pixels=%0d",new_frames,repeat_frames,checked_pixels);
   $fflush();
  end
  if(rst_n && de && tag_valid)begin
   case(displayed_id)
    64'd1:expected_rgb=24'h494949;
    64'd3:expected_rgb=24'h727272;
    64'd4:expected_rgb=24'h5b5b5b;
    default:$fatal(1,"DISPLAY_CORE unknown source frame %0d",displayed_id);
   endcase
   if(displayed_epoch!==64'hf123456789abcdef || rgb!==expected_rgb)
    $fatal(1,"DISPLAY_CORE pixel/identity differs id=%0d rgb=%h",displayed_id,rgb);
   checked_pixels=checked_pixels+1;
  end
 end
endmodule
