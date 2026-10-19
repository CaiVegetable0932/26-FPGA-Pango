`timescale 1ns/1ps
`include "frame_manager_layout.vh"
// Purpose: DDR-domain slot ownership with independent producer, four consumer
// and tagged transaction lanes. No request-level CDC is performed here. Every
// completion is a unique token/ticket retired only at the adapter's drain fence.
// Packed vector field slices use generated offsets from frame_manager_pkg.sv;
// no wide structure variable participates in the synthesis core's DFF inference.
module frame_pool_bank #(
 parameter integer SLOTS=3,
 parameter [31:0] BASE=0, SLOT_BYTES=32'h00800000,
 parameter integer TXNS=3,
 parameter [31:0] STRIDE=6144
)(
 input wire clk, reset_n, fabric_ready, display_boundary,
 input wire [`FM_CMD_BITS-1:0] cmd,
 output reg [`FM_RSP_BITS-1:0] rsp
);
 import frame_manager_pkg::*;
 reg busy[0:SLOTS-1], sealed[0:SLOTS-1], legal[0:SLOTS-1];
 reg announced[0:SLOTS-1], bad_counted[0:SLOTS-1];
 reg [3:0] pending[0:SLOTS-1], refs[0:SLOTS-1];
 reg [31:0] generation[0:SLOTS-1];
 // Purpose: retain the full 64-bit allocation exhaustion fence. This counter
 // is not an encoded slot rank and still saturates by refusing new allocation.
 reg [63:0] next_order;
 // older[a*SLOTS+b] means busy slot a was allocated before busy slot b.
 // Only comparisons of two busy/pending slots read this payload relation.
 // Allocation installs the new slot as newest; all other pairwise relations
 // remain unchanged. Free-slot reuse and cold reset rebuild its row/column
 // before ownership exposes it. No absolute order bits enter the public ABI.
 reg [SLOTS*SLOTS-1:0] older;
 // Purpose: retain allocation-only descriptor fields without imposing a RAM
 // minimum depth on one-slot snapshot banks. Multi-slot banks keep the tested
 // asynchronous distributed RAM implementation; SLOTS=1 uses clock-only FF.
 // Neither branch resets payload. Resettable busy/ownership guards prevent
 // acquisition/SEAL from observing stale payload before a fresh allocation.
 wire [META_BITS-1:0] allocation_meta=cmd[`FM_CMD_META];
 // Compressed schema: reverse packed order of every named immutable field.
 // Widths come from generated FM_META slices, rather than naked ABI offsets.
 // Reordering existing packed fields remains safe because expansion writes
 // each named field. Adding a field requires including it in this schema.
 localparam integer CAPTURE_LAST_BITS=$bits(allocation_meta[`FM_META_CAPTURE_LAST]);
 localparam integer ERROR_BITS=$bits(allocation_meta[`FM_META_ERRORS]);
 localparam integer C_POSE_STATUS=0;
 localparam integer C_ENHANCEMENT_STAGE=C_POSE_STATUS+$bits(allocation_meta[`FM_META_POSE_STATUS]);
 localparam integer C_STAGE=C_ENHANCEMENT_STAGE+$bits(allocation_meta[`FM_META_ENHANCEMENT_STAGE]);
 localparam integer C_FORMAT=C_STAGE+$bits(allocation_meta[`FM_META_STAGE]);
 localparam integer C_HEIGHT=C_FORMAT+$bits(allocation_meta[`FM_META_FORMAT]);
 localparam integer C_WIDTH=C_HEIGHT+$bits(allocation_meta[`FM_META_HEIGHT]);
 localparam integer C_STRIDE=C_WIDTH+$bits(allocation_meta[`FM_META_WIDTH]);
 localparam integer C_MODE=C_STRIDE+$bits(allocation_meta[`FM_META_STRIDE]);
 localparam integer C_POSE_ENTITY=C_MODE+$bits(allocation_meta[`FM_META_MODE]);
 localparam integer C_PARAMETER_ENTITY=C_POSE_ENTITY+$bits(allocation_meta[`FM_META_POSE_ENTITY]);
 localparam integer C_CALIBRATION_ENTITY=C_PARAMETER_ENTITY+$bits(allocation_meta[`FM_META_PARAMETER_ENTITY]);
 localparam integer C_ENHANCEMENT_VERSION=C_CALIBRATION_ENTITY+$bits(allocation_meta[`FM_META_CALIBRATION_ENTITY]);
 localparam integer C_GEOMETRY_VERSION=C_ENHANCEMENT_VERSION+$bits(allocation_meta[`FM_META_ENHANCEMENT_VERSION]);
 localparam integer C_ISP_VERSION=C_GEOMETRY_VERSION+$bits(allocation_meta[`FM_META_GEOMETRY_VERSION]);
 localparam integer C_CAPTURE_FIRST=C_ISP_VERSION+$bits(allocation_meta[`FM_META_ISP_VERSION]);
 localparam integer C_FRAME_ID=C_CAPTURE_FIRST+$bits(allocation_meta[`FM_META_CAPTURE_FIRST]);
 localparam integer C_EPOCH=C_FRAME_ID+$bits(allocation_meta[`FM_META_FRAME_ID]);
 localparam integer IMMUTABLE_META_BITS=C_EPOCH+$bits(allocation_meta[`FM_META_EPOCH]);
 wire [IMMUTABLE_META_BITS-1:0] allocation_immutable={
  allocation_meta[`FM_META_EPOCH],allocation_meta[`FM_META_FRAME_ID],
  allocation_meta[`FM_META_CAPTURE_FIRST],allocation_meta[`FM_META_ISP_VERSION],
  allocation_meta[`FM_META_GEOMETRY_VERSION],allocation_meta[`FM_META_ENHANCEMENT_VERSION],
  allocation_meta[`FM_META_CALIBRATION_ENTITY],allocation_meta[`FM_META_PARAMETER_ENTITY],
  allocation_meta[`FM_META_POSE_ENTITY],allocation_meta[`FM_META_MODE],
  allocation_meta[`FM_META_STRIDE],allocation_meta[`FM_META_WIDTH],
  allocation_meta[`FM_META_HEIGHT],allocation_meta[`FM_META_FORMAT],
  allocation_meta[`FM_META_STAGE],allocation_meta[`FM_META_ENHANCEMENT_STAGE],
  allocation_meta[`FM_META_POSE_STATUS]};
 // The current schema covers 520 immutable + 64 last + 32 error bits. A newly
 // added field must fail elaboration, rather than silently disappear in RAM.
 generate if(META_BITS!=IMMUTABLE_META_BITS+CAPTURE_LAST_BITS+ERROR_BITS) begin : bad_metadata_schema
  FRAME_METADATA_SCHEMA_REQUIRES_UPDATE schema_must_include_every_field();
 end endgenerate
 // Branch-local storage exposes only dynamic consumer read ports. Do not
 // broadcast every slot through constant read aliases: installed ADS mapped
 // that structure to FF instead of the requested distributed RAM.
 wire [IMMUTABLE_META_BITS-1:0] consumer_immutable[0:3];
 reg [CAPTURE_LAST_BITS-1:0] capture_last[0:SLOTS-1];
 reg [ERROR_BITS-1:0] metadata_errors[0:SLOTS-1];
 // Purpose: reconstruct the entire authoritative descriptor by named fields.
 // This is combinational wiring only; it adds no latency or payload truncation.
 function [META_BITS-1:0] expand_metadata;
  input [IMMUTABLE_META_BITS-1:0] immutable;
  input [CAPTURE_LAST_BITS-1:0] last;
  input [ERROR_BITS-1:0] errors;
  begin
   expand_metadata='0;
   expand_metadata[`FM_META_EPOCH]=immutable[C_EPOCH+:$bits(allocation_meta[`FM_META_EPOCH])];
   expand_metadata[`FM_META_FRAME_ID]=immutable[C_FRAME_ID+:$bits(allocation_meta[`FM_META_FRAME_ID])];
   expand_metadata[`FM_META_CAPTURE_FIRST]=immutable[C_CAPTURE_FIRST+:$bits(allocation_meta[`FM_META_CAPTURE_FIRST])];
   expand_metadata[`FM_META_ISP_VERSION]=immutable[C_ISP_VERSION+:$bits(allocation_meta[`FM_META_ISP_VERSION])];
   expand_metadata[`FM_META_GEOMETRY_VERSION]=immutable[C_GEOMETRY_VERSION+:$bits(allocation_meta[`FM_META_GEOMETRY_VERSION])];
   expand_metadata[`FM_META_ENHANCEMENT_VERSION]=immutable[C_ENHANCEMENT_VERSION+:$bits(allocation_meta[`FM_META_ENHANCEMENT_VERSION])];
   expand_metadata[`FM_META_CALIBRATION_ENTITY]=immutable[C_CALIBRATION_ENTITY+:$bits(allocation_meta[`FM_META_CALIBRATION_ENTITY])];
   expand_metadata[`FM_META_PARAMETER_ENTITY]=immutable[C_PARAMETER_ENTITY+:$bits(allocation_meta[`FM_META_PARAMETER_ENTITY])];
   expand_metadata[`FM_META_POSE_ENTITY]=immutable[C_POSE_ENTITY+:$bits(allocation_meta[`FM_META_POSE_ENTITY])];
   expand_metadata[`FM_META_MODE]=immutable[C_MODE+:$bits(allocation_meta[`FM_META_MODE])];
   expand_metadata[`FM_META_STRIDE]=immutable[C_STRIDE+:$bits(allocation_meta[`FM_META_STRIDE])];
   expand_metadata[`FM_META_WIDTH]=immutable[C_WIDTH+:$bits(allocation_meta[`FM_META_WIDTH])];
   expand_metadata[`FM_META_HEIGHT]=immutable[C_HEIGHT+:$bits(allocation_meta[`FM_META_HEIGHT])];
   expand_metadata[`FM_META_FORMAT]=immutable[C_FORMAT+:$bits(allocation_meta[`FM_META_FORMAT])];
   expand_metadata[`FM_META_STAGE]=immutable[C_STAGE+:$bits(allocation_meta[`FM_META_STAGE])];
   expand_metadata[`FM_META_ENHANCEMENT_STAGE]=immutable[C_ENHANCEMENT_STAGE+:$bits(allocation_meta[`FM_META_ENHANCEMENT_STAGE])];
   expand_metadata[`FM_META_POSE_STATUS]=immutable[C_POSE_STATUS+:$bits(allocation_meta[`FM_META_POSE_STATUS])];
   expand_metadata[`FM_META_CAPTURE_LAST]=last;
   expand_metadata[`FM_META_ERRORS]=errors;
  end
 endfunction
 reg token_busy[0:TXNS-1];
 reg [1:0] token_slot[0:TXNS-1];
 reg [63:0] ticket[0:TXNS-1];
 reg [2:0] token_owner[0:TXNS-1];
 // Each count is bounded by the explicit token scoreboard capacity. Narrow
 // count trees preserve simultaneous issue/complete semantics without a
 // 32-bit integer accumulator in every slot's readiness logic.
 localparam COUNT_BITS=$clog2(TXNS+1);
 reg [COUNT_BITS-1:0] inflight[0:SLOTS-1], writes[0:SLOTS-1];
 integer a, t, c, selected[0:3], free_slot, free_token, occupancy;
 reg frame_ready[0:SLOTS-1];
 reg [31:0] published, invalid_frames, rejected_cycles, skipped;
 reg [2:0] peak_slots;
 // Purpose: aliases avoid unsupported ADS struct-member bit selects. Flattened
 // vectors carry all four consumers atomically in the memory clock domain.
 wire [3:0] acq=cmd[`FM_CMD_ACQUIRE], rel=cmd[`FM_CMD_RELEASE_MASK], skip=cmd[`FM_CMD_SKIP_MASK];
 wire [7:0] rel_slots=cmd[`FM_CMD_RELEASE_SLOTS];
 wire [127:0] rel_gens=cmd[`FM_CMD_RELEASE_GENS];
 reg [3:0] acq_ok, rel_ok, skip_ok;
 reg [7:0] acq_slots;
 reg [127:0] acq_gens;
 reg [4*META_BITS-1:0] acq_meta;
 reg [2:0] occupied_bits, ready_bits;
 // The original SEAL slot/generation/busy check gates every use of this read.
 // Reading an invalid command address is harmless because no legal SEAL then
 // observes its payload; allocation and acquisition use different owned slots.
 wire [63:0] seal_capture_first;
 reg issue_owner_ok, event_error, alloc_shape_ok, drain_error[0:SLOTS-1];
 integer k;

 // Purpose: derive exact in-flight counts from a bounded token scoreboard.
 // Independent issue/complete cannot lose a count in a same-cycle RMW race.
 // A busy token keeps its slot busy until retirement: ISSUE verifies the public
 // generation, and inflight prevents release/reallocation. Thus an internal
 // token-generation copy is redundant for all reachable states. The original
 // public generation checks and 64-bit ticket/ABA fences remain mandatory.
 // Cancel waits for drain; quarantine holds both slot and token controls.
 // A final COMPLETE still counts in this edge's pre-state, delaying reuse.
 always @* begin
  occupancy=0; free_slot=-1; free_token=-1;
  occupied_bits=0; ready_bits=0;
  for(a=0;a<SLOTS;a=a+1) begin
   inflight[a]=0; writes[a]=0;
   drain_error[a]=0;
   for(t=0;t<TXNS;t=t+1)
    if(token_busy[t] && token_slot[t]==a) begin
     inflight[a]=inflight[a]+1;
     if(token_owner[t]==0) writes[a]=writes[a]+1;
     if(cmd[`FM_CMD_COMPLETE] && cmd[`FM_CMD_COMPLETE_TOKEN]==t && cmd[`FM_CMD_COMPLETE_TICKET]==ticket[t] &&
        cmd[`FM_CMD_COMPLETE_ERROR]) drain_error[a]=1;
    end
   frame_ready[a]=busy[a] && sealed[a] && legal[a] && writes[a]==0;
   occupied_bits[a]=busy[a]; ready_bits[a]=frame_ready[a];
   if(busy[a]) occupancy=occupancy+1;
   // Saturating generations/order quarantine exhausted slots instead of ABA.
   if(free_slot<0 && !busy[a] && generation[a]!=32'hffffffff &&
      next_order!=64'hffffffffffffffff) free_slot=a;
  end
  for(t=0;t<TXNS;t=t+1)
   if(free_token<0 && !token_busy[t] && ticket[t]!=64'hffffffffffffffff) free_token=t;

  rsp='0;
  rsp[`FM_RSP_OCCUPIED]=occupied_bits; rsp[`FM_RSP_READY_FRAMES]=ready_bits;
  rsp[`FM_RSP_PUBLISHED]=published; rsp[`FM_RSP_INVALID_FRAMES]=invalid_frames;
  rsp[`FM_RSP_REJECTED_CYCLES]=rejected_cycles; rsp[`FM_RSP_SKIPPED]=skipped; rsp[`FM_RSP_PEAK_SLOTS]=peak_slots;
  acq_ok=0; rel_ok=0; skip_ok=0; acq_slots=0; acq_gens=0; acq_meta=0;
  event_error=0; issue_owner_ok=0;
  for(c=0;c<4;c=c+1) selected[c]=-1;
  // Authoritative strides cover at most 1920x1080; constant span validation
  // avoids a wide metadata multiplier on the allocation-critical path.
  alloc_shape_ok=allocation_meta[`FM_META_WIDTH]!=0 && allocation_meta[`FM_META_WIDTH]<=1920 &&
   allocation_meta[`FM_META_HEIGHT]!=0 && allocation_meta[`FM_META_HEIGHT]<=1080 && allocation_meta[`FM_META_STRIDE]==STRIDE &&
   allocation_meta[`FM_META_FORMAT]==(STRIDE==2048?1:2) && (STRIDE*1080)<=SLOT_BYTES;
  // Evaluate nominal ownership/interlocks without distributing fabric_ready
  // through release -> issue -> rejection chains. Readiness gates the final
  // response and every sequential update; no operation commits while stopped.
  begin
   rsp[`FM_RSP_ALLOC_READY]=(free_slot>=0) && alloc_shape_ok;
   if(free_slot>=0) begin
    rsp[`FM_RSP_ALLOC_SLOT]=free_slot; rsp[`FM_RSP_ALLOC_GEN]=generation[free_slot]+1'b1;
    rsp[`FM_RSP_ALLOC_BASE]=BASE+free_slot*SLOT_BYTES;
   end
   for(a=0;a<SLOTS;a=a+1) begin
    if(cmd[`FM_CMD_SEAL] && cmd[`FM_CMD_SEAL_SLOT]==a && busy[a] && !sealed[a] &&
       cmd[`FM_CMD_SEAL_GEN]==generation[a]) rsp[`FM_RSP_SEAL_OK]=1;
    if(cmd[`FM_CMD_CANCEL] && cmd[`FM_CMD_CANCEL_SLOT]==a && busy[a] &&
       cmd[`FM_CMD_CANCEL_GEN]==generation[a]) rsp[`FM_RSP_CANCEL_OK]=1;
   end
   // A source's pending claim is installed at allocation, so an earlier slow
   // frame blocks acquisition of a later complete frame. Exact selection is
   // restricted to the diagnostic snapshot consumer, with a generation check.
   for(c=0;c<4;c=c+1) begin
    for(a=0;a<SLOTS;a=a+1)
     if(busy[a] && pending[a][c] &&
        (c!=SNAPSHOT || !cmd[`FM_CMD_SNAP_EXACT] ||
         (cmd[`FM_CMD_SNAP_SLOT]==a && cmd[`FM_CMD_SNAP_GEN]==generation[a])))
      if(selected[c]<0) selected[c]=a;
      else if(older[a*SLOTS+selected[c]]) selected[c]=a;
    if(selected[c]>=0 && acq[c] && (c!=DISPLAY || display_boundary) &&
       frame_ready[selected[c]] && !drain_error[selected[c]] &&
       !(cmd[`FM_CMD_CANCEL] && cmd[`FM_CMD_CANCEL_SLOT]==selected[c] && rsp[`FM_RSP_CANCEL_OK])) begin
     acq_ok[c]=1; acq_slots[2*c+:2]=selected[c];
     acq_gens[32*c+:32]=generation[selected[c]];
     // Restore the exact packed ABI around separately updated mutable fields.
     // All pieces sample the same selected slot without adding a clock stage.
     acq_meta[META_BITS*c+:META_BITS]=expand_metadata(consumer_immutable[c],
      capture_last[selected[c]],metadata_errors[selected[c]]);
    end
    for(a=0;a<SLOTS;a=a+1)
     if(busy[a] && rel_slots[2*c+:2]==a && rel_gens[32*c+:32]==generation[a]) begin
      if(rel[c] && refs[a][c]) rel_ok[c]=1;
      // Required processing/display claims cannot be silently waived. Network
      // failure or an unselected snapshot can explicitly drop a pending claim.
      if(skip[c] && c>=NETWORK && pending[a][c] &&
         !(acq_ok[c] && selected[c]==a)) skip_ok[c]=1;
     end
    if((rel[c] && !rel_ok[c]) || (skip[c] && !skip_ok[c])) event_error=1;
   end
   for(a=0;a<SLOTS;a=a+1)
    if(cmd[`FM_CMD_ISSUE_SLOT]==a && busy[a] && cmd[`FM_CMD_ISSUE_GEN]==generation[a] &&
       !drain_error[a] && !(cmd[`FM_CMD_CANCEL] && rsp[`FM_RSP_CANCEL_OK] && cmd[`FM_CMD_CANCEL_SLOT]==a)) begin
     if(cmd[`FM_CMD_ISSUE_OWNER]==0)
      issue_owner_ok=!sealed[a] && !(cmd[`FM_CMD_SEAL] && rsp[`FM_RSP_SEAL_OK] && cmd[`FM_CMD_SEAL_SLOT]==a);
     for(c=0;c<4;c=c+1)
      if(cmd[`FM_CMD_ISSUE_OWNER]==c+1)
       issue_owner_ok=frame_ready[a] && refs[a][c] &&
        !(rel[c] && rel_ok[c] && rel_slots[2*c+:2]==a);
    end
   rsp[`FM_RSP_ISSUE_READY]=issue_owner_ok && free_token>=0;
   rsp[`FM_RSP_ISSUE_REJECTED]=cmd[`FM_CMD_ISSUE] && !issue_owner_ok;
   if(free_token>=0) begin
    rsp[`FM_RSP_ISSUE_TOKEN]=free_token; rsp[`FM_RSP_ISSUE_TICKET]=ticket[free_token]+1'b1;
   end
   for(t=0;t<TXNS;t=t+1)
    if(cmd[`FM_CMD_COMPLETE] && cmd[`FM_CMD_COMPLETE_TOKEN]==t && token_busy[t] &&
       cmd[`FM_CMD_COMPLETE_TICKET]==ticket[t]) rsp[`FM_RSP_COMPLETE_OK]=1;
   if((cmd[`FM_CMD_ALLOC] && !alloc_shape_ok) || (cmd[`FM_CMD_SEAL] && !rsp[`FM_RSP_SEAL_OK]) || (cmd[`FM_CMD_CANCEL] && !rsp[`FM_RSP_CANCEL_OK]) ||
      (cmd[`FM_CMD_COMPLETE] && !rsp[`FM_RSP_COMPLETE_OK]) || (cmd[`FM_CMD_ISSUE] && !issue_owner_ok)) event_error=1;
  end
  rsp[`FM_RSP_ACQUIRE_OK]=acq_ok; rsp[`FM_RSP_ACQUIRE_SLOTS]=acq_slots;
  rsp[`FM_RSP_ACQUIRE_GENS]=acq_gens; rsp[`FM_RSP_ACQUIRE_META]=acq_meta;
  rsp[`FM_RSP_RELEASE_OK]=rel_ok; rsp[`FM_RSP_SKIP_OK]=skip_ok; rsp[`FM_RSP_REJECTED]=event_error;
  if(!fabric_ready) begin
   // Diagnostics remain observable during quarantine, as in the original
   // contract; all operation ACKs and descriptor payloads are inactive.
   rsp='0;
   rsp[`FM_RSP_OCCUPIED]=occupied_bits; rsp[`FM_RSP_READY_FRAMES]=ready_bits;
   rsp[`FM_RSP_PUBLISHED]=published; rsp[`FM_RSP_INVALID_FRAMES]=invalid_frames;
   rsp[`FM_RSP_REJECTED_CYCLES]=rejected_cycles; rsp[`FM_RSP_SKIPPED]=skipped;
   rsp[`FM_RSP_PEAK_SLOTS]=peak_slots;
  end
 end

 // Purpose: preserve the exact allocation commit edge and fabric_ready hold.
 // With one slot, every accepted write address and every valid read address is
 // zero. The held vector is FF storage with shared asynchronous consumers;
 // invalid read addresses remain unknown and are excluded by the same gates.
 // Multi-slot storage retains one dynamic write and asynchronous read ports.
 generate if(SLOTS==1) begin : single_slot_metadata
  reg [IMMUTABLE_META_BITS-1:0] held_descriptor /* synthesis syn_ramstyle="registers" */;
  // Invalid addresses remain unknown internally, as in the original array;
  // existing ownership/SEAL validity gates exclude them from all responses.
  genvar single_consumer;
  for(single_consumer=0;single_consumer<4;single_consumer=single_consumer+1) begin : consumer_read
   assign consumer_immutable[single_consumer]=(selected[single_consumer]==0)?
    held_descriptor:{IMMUTABLE_META_BITS{1'bx}};
  end
  assign seal_capture_first=(cmd[`FM_CMD_SEAL_SLOT]==0)?
   held_descriptor[C_CAPTURE_FIRST+:$bits(allocation_meta[`FM_META_CAPTURE_FIRST])]:64'bx;
  always @(posedge clk)
   if(fabric_ready && cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY])
    held_descriptor<=allocation_immutable;
 end else begin : multi_slot_metadata
  reg [IMMUTABLE_META_BITS-1:0] storage[0:SLOTS-1] /* synthesis syn_ramstyle="lut_ram" */;
  // Official ADS asynchronous SDP template reads the actual memory with
  // a dynamic address. Keep each consumer and SEAL directly on that boundary;
  // the shared expansion function receives read data, not a broadcast slot list.
  genvar multi_consumer;
  for(multi_consumer=0;multi_consumer<4;multi_consumer=multi_consumer+1) begin : consumer_read
   assign consumer_immutable[multi_consumer]=storage[selected[multi_consumer]];
  end
  assign seal_capture_first=storage[cmd[`FM_CMD_SEAL_SLOT]]
   [C_CAPTURE_FIRST+:$bits(allocation_meta[`FM_META_CAPTURE_FIRST])];
  always @(posedge clk)
   if(fabric_ready && cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY])
    storage[rsp[`FM_RSP_ALLOC_SLOT]]<=allocation_immutable;
 end endgenerate

 // Each slot still owns resettable control and the mutable descriptor fields.
 // Cancel/error override seal; allocation wins every payload update for its
 // pre-free slot, exactly as in the original constant-address register banks.
 genvar slot_number;
 generate for(slot_number=0;slot_number<SLOTS;slot_number=slot_number+1) begin : slots
  reg [3:0] next_pending, next_refs;
  reg next_sealed, next_legal;
  reg [`FM_META_BITS-1:0] next_meta;
  wire allocate_slot=cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY] &&
                     rsp[`FM_RSP_ALLOC_SLOT]==slot_number;
  wire seal_slot=cmd[`FM_CMD_SEAL] && rsp[`FM_RSP_SEAL_OK] &&
                 cmd[`FM_CMD_SEAL_SLOT]==slot_number;
  wire cancel_slot=cmd[`FM_CMD_CANCEL] && rsp[`FM_RSP_CANCEL_OK] &&
                   cmd[`FM_CMD_CANCEL_SLOT]==slot_number;
  reg complete_error_slot;
  integer owner, transaction;
  always @* begin
   next_pending=pending[slot_number]; next_refs=refs[slot_number];
   next_sealed=sealed[slot_number]; next_legal=legal[slot_number];
   // Only mutable slices participate in this next-state function. The other
   // descriptor slices are read directly from immutable storage at acquisition.
   next_meta='0;
   next_meta[`FM_META_CAPTURE_LAST]=capture_last[slot_number];
   next_meta[`FM_META_ERRORS]=metadata_errors[slot_number];
   complete_error_slot=0;
   for(owner=0;owner<4;owner=owner+1) begin
    if(acq_ok[owner] && acq_slots[2*owner+:2]==slot_number) begin
     next_pending[owner]=0; next_refs[owner]=1;
    end
    if(rel_ok[owner] && rel_slots[2*owner+:2]==slot_number) next_refs[owner]=0;
    if(skip_ok[owner] && rel_slots[2*owner+:2]==slot_number) next_pending[owner]=0;
   end
   if(cmd[`FM_CMD_SEAL] && rsp[`FM_RSP_SEAL_OK] && cmd[`FM_CMD_SEAL_SLOT]==slot_number) begin
    next_sealed=1;
    next_legal=cmd[`FM_CMD_LEGAL] && cmd[`FM_CMD_FRAME_ERRORS]==0 && next_meta[`FM_META_ERRORS]==0 &&
     cmd[`FM_CMD_CAPTURE_LAST]>=seal_capture_first;
    if(!next_legal) next_pending=0;
    next_meta[`FM_META_CAPTURE_LAST]=cmd[`FM_CMD_CAPTURE_LAST];
    next_meta[`FM_META_ERRORS]=next_meta[`FM_META_ERRORS] | cmd[`FM_CMD_FRAME_ERRORS];
   end
   if(cmd[`FM_CMD_CANCEL] && rsp[`FM_RSP_CANCEL_OK] && cmd[`FM_CMD_CANCEL_SLOT]==slot_number) begin
    next_sealed=1; next_legal=0; next_pending=0;
    next_meta[`FM_META_ERRORS]=next_meta[`FM_META_ERRORS] | 32'h80000000;
   end
   for(transaction=0;transaction<TXNS;transaction=transaction+1)
    if(cmd[`FM_CMD_COMPLETE] && rsp[`FM_RSP_COMPLETE_OK] && cmd[`FM_CMD_COMPLETE_TOKEN]==transaction &&
       token_slot[transaction]==slot_number && cmd[`FM_CMD_COMPLETE_ERROR]) begin
     complete_error_slot=1;
     next_sealed=1; next_legal=0; next_pending=0;
     next_meta[`FM_META_ERRORS]=next_meta[`FM_META_ERRORS] | 32'h40000000;
    end
  end
  always @(posedge clk or negedge reset_n) begin
   if(!reset_n) begin
    busy[slot_number]<=0; sealed[slot_number]<=0; legal[slot_number]<=0;
    pending[slot_number]<=0; refs[slot_number]<=0; generation[slot_number]<=0;
    announced[slot_number]<=0; bad_counted[slot_number]<=0;
   end else if(fabric_ready) begin
    pending[slot_number]<=next_pending; refs[slot_number]<=next_refs;
    sealed[slot_number]<=next_sealed; legal[slot_number]<=next_legal;
    if(frame_ready[slot_number] && !announced[slot_number]) announced[slot_number]<=1;
    if(busy[slot_number] && sealed[slot_number] && !legal[slot_number] && !bad_counted[slot_number])
     bad_counted[slot_number]<=1;
    if(busy[slot_number] && sealed[slot_number] && inflight[slot_number]==0 &&
       pending[slot_number]==0 && refs[slot_number]==0) busy[slot_number]<=0;
    if(cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY] && rsp[`FM_RSP_ALLOC_SLOT]==slot_number) begin
     busy[slot_number]<=1; sealed[slot_number]<=0; legal[slot_number]<=0;
     pending[slot_number]<=cmd[`FM_CMD_CONSUMERS]; refs[slot_number]<=0;
     generation[slot_number]<=rsp[`FM_RSP_ALLOC_GEN];
     announced[slot_number]<=0; bad_counted[slot_number]<=0;
    end
   end
  end
  // Mutable metadata payload retains the baseline's unreset clock-only hold.
  // Their valid ownership bits remain asynchronously cleared, and allocation
  // initializes every bit before SEAL/acquisition can observe it. next_meta
  // retains the original SEAL -> CANCEL -> completion-error OR precedence.
  always @(posedge clk) begin
   if(fabric_ready) begin
    if(allocate_slot) begin
     capture_last[slot_number]<=allocation_meta[`FM_META_CAPTURE_LAST];
     metadata_errors[slot_number]<=allocation_meta[`FM_META_ERRORS];
    end else begin
     if(seal_slot) capture_last[slot_number]<=next_meta[`FM_META_CAPTURE_LAST];
     if(seal_slot || cancel_slot || complete_error_slot)
      metadata_errors[slot_number]<=next_meta[`FM_META_ERRORS];
    end
   end
  end
 end endgenerate
 // Purpose: update only the row/column for the sole accepted allocation.
 // Pre-edge free-slot selection cannot reuse a slot released on this edge.
 // Existing busy peers are therefore strictly older, including peers whose
 // final drain/release happens concurrently. Their later busy=0 masks stale
 // relations; allocation of either endpoint rebuilds the pair before use.
 // Like the original order_id payload, this bank has no reset. Resettable
 // busy/pending protects unknown values until fresh allocation establishes
 // every relation between live slots. next_order/generation/tickets keep
 // their original full-width reset, increment and exhaustion semantics.
 genvar order_row, order_column;
 generate for(order_row=0;order_row<SLOTS;order_row=order_row+1) begin : order_rows
  for(order_column=0;order_column<SLOTS;order_column=order_column+1) begin : order_columns
   always @(posedge clk)
    if(fabric_ready && cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY]) begin
     if(rsp[`FM_RSP_ALLOC_SLOT]==order_row)
      older[order_row*SLOTS+order_column]<=0;
     else if(rsp[`FM_RSP_ALLOC_SLOT]==order_column)
      older[order_row*SLOTS+order_column]<=busy[order_row];
    end
  end
 end endgenerate
 // Purpose: bank-level order, event counters and token scoreboard have exactly
 // one writer. Concurrent token issue/retire uses distinct pre-free entries.
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   published<=0; invalid_frames<=0; rejected_cycles<=0;
   skipped<=0; peak_slots<=0;
   for(k=0;k<TXNS;k=k+1) begin
    token_busy[k]<=0;
   end
  end else if(fabric_ready) begin
   if(event_error) rejected_cycles<=rejected_cycles+1'b1;
   if(occupancy>peak_slots) peak_slots<=occupancy;

   for(k=0;k<TXNS;k=k+1) begin
    if(cmd[`FM_CMD_COMPLETE] && rsp[`FM_RSP_COMPLETE_OK] && cmd[`FM_CMD_COMPLETE_TOKEN]==k) token_busy[k]<=0;
    if(cmd[`FM_CMD_ISSUE] && rsp[`FM_RSP_ISSUE_READY] && rsp[`FM_RSP_ISSUE_TOKEN]==k) begin
     token_busy[k]<=1;
    end
   end
   published<=published+publish_increment;
   invalid_frames<=invalid_frames+invalid_increment;
   skipped<=skipped+skip_increment;
  end
 end
 // Keep the complete 64-bit values and existing exhaustion fences.
 // Each chunk adds its accepted-event carry from the SAME pre-edge lower
 // bits. No counter update is delayed and no ticket bits are discarded.
 // Continuous add-with-carry targets the measured wide CE endpoint, rather
 // than copying a high-fanout authorization signal into another wide CE.
 wire accepted_alloc=fabric_ready && cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY];
 genvar counter_word,counter_token;
 generate for(counter_word=0;counter_word<8;counter_word=counter_word+1) begin : order_chunks
  wire increment;
  if(counter_word==0)assign increment=accepted_alloc;
  else assign increment=accepted_alloc && (&next_order[counter_word*8-1:0]);
  always @(posedge clk or negedge reset_n)
   if(!reset_n)next_order[counter_word*8+:8]<=0;
   else next_order[counter_word*8+:8]<=next_order[counter_word*8+:8]+increment;
 end
 for(counter_token=0;counter_token<TXNS;counter_token=counter_token+1) begin : token_counter_chunks
  wire accepted_issue=fabric_ready && cmd[`FM_CMD_ISSUE] && rsp[`FM_RSP_ISSUE_READY] &&
   rsp[`FM_RSP_ISSUE_TOKEN]==counter_token;
  for(counter_word=0;counter_word<8;counter_word=counter_word+1) begin : word_counter
   wire increment;
   if(counter_word==0)assign increment=accepted_issue;
   else assign increment=accepted_issue && (&ticket[counter_token][counter_word*8-1:0]);
   always @(posedge clk or negedge reset_n)
    if(!reset_n)ticket[counter_token][counter_word*8+:8]<=0;
    else ticket[counter_token][counter_word*8+:8]<=ticket[counter_token][counter_word*8+:8]+increment;
  end
 end endgenerate
 // Transaction slot/owner payload is written atomically with token_busy and is
 // read only for a busy token (including COMPLETE_OK's ticket check). Ticket
 // counters retain reset and saturation because free-token selection reads
 // them while idle. Slot ownership cannot recycle while a token is busy;
 // stale slot/owner payload is masked by token_busy and overwritten on ISSUE.
 genvar token_number;
 generate for(token_number=0;token_number<TXNS;token_number=token_number+1) begin : token_payloads
  always @(posedge clk)
   if(fabric_ready && cmd[`FM_CMD_ISSUE] && rsp[`FM_RSP_ISSUE_READY] &&
      rsp[`FM_RSP_ISSUE_TOKEN]==token_number) begin
    token_slot[token_number]<=cmd[`FM_CMD_ISSUE_SLOT];
    token_owner[token_number]<=cmd[`FM_CMD_ISSUE_OWNER];
   end
 end endgenerate
 // Purpose: exact concurrent event counts, including several releases/drains.
 integer publish_increment, invalid_increment, skip_increment, j;
 always @* begin
  publish_increment=0; invalid_increment=0; skip_increment=0;
  for(j=0;j<SLOTS;j=j+1) begin
   if(frame_ready[j] && !announced[j]) publish_increment=publish_increment+1;
   if(busy[j] && sealed[j] && !legal[j] && !bad_counted[j]) invalid_increment=invalid_increment+1;
  end
  for(j=0;j<4;j=j+1) if(skip_ok[j]) skip_increment=skip_increment+1;
 end
endmodule
