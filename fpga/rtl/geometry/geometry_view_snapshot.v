// Purpose: result-slot metadata, held-bus CDC, final-overlay frame activation,
// and coherent bank-2 readback. No externally captured frame ID is inferred.
module geometry_view_snapshot #(
 // Opt-in UART path: address is stable before CRC/acceptance. Register only
 // its division/range decode, never the live snapshot or displayed version.
 parameter PREDECODE_READ=0)(input wire mem_clk,mem_rst_n,pixel_clk,pixel_rst_n,
 input wire commit,input wire [1:0] result_slot,input wire [1279:0] coordinates,
 input wire [19:0] visible_mask,input wire [31:0] revision,packed_control,version,status,
 input wire lease,input wire [1:0] lease_slot,output wire lease_ready,
 input wire pixel_request,pixel_frame_ack,input wire in_vs,in_de,
 input wire [31:0] read_index,output reg [31:0] read_value,output wire read_valid,
 output reg [31:0] applied_revision,applied_packed,applied_version,generation,
 output reg [1279:0] pixel_coordinates,output reg [19:0] pixel_visible,
 output reg [31:0] pixel_packed);
 localparam BITS=1428;
 reg [BITS-1:0] slots[0:2],held_bus,pixel_pending,snapshot;
 reg request_toggle;reg pixel_ack_toggle,display_toggle;
 (* syn_preserve=1 *) reg req_meta,req_sync,ack_meta,ack_sync,display_meta,display_sync;
 (* syn_preserve=1 *) reg frame_ack_meta,frame_ack_sync;
 reg display_seen,previous_vs,previous_request,armed,pending_valid,await_display;
 // Purpose: cap equality depth at 32 data bits. Preserved register stages
 // prevent synthesis from rebuilding one 1428-bit carry-chain comparison.
 wire [63:0] compare_chunks;
 (* syn_preserve=1 *) reg [5:0] compare_groups;
 (* syn_preserve=1 *) reg metadata_changed;
 genvar comparison;
 generate for(comparison=0;comparison<64;comparison=comparison+1)begin:g_compare
  localparam LO=comparison*32;
  if(LO<BITS)begin:used_chunk
   localparam CHUNK_BITS=(BITS-LO>=32)?32:BITS-LO;
   (* syn_preserve=1 *) reg changed_q;
   assign compare_chunks[comparison]=changed_q;
   always @(posedge mem_clk or negedge mem_rst_n)
    if(!mem_rst_n)changed_q<=0;
    else changed_q<=|(held_bus[LO+:CHUNK_BITS]^snapshot[LO+:CHUNK_BITS]);
  end else begin:padding
   // Purpose: unused equality padding is a wire, not a preserved constant
   // flop. ADS must not turn its reset into a spurious SRB-routed clock.
   assign compare_chunks[comparison]=1'b0;
  end
 end
 // Only six groups contain any of the 45 real chunks; the other two were
 // constant zero and must not create preserved, clockless padding flops.
 for(comparison=0;comparison<6;comparison=comparison+1)begin:g_compare_group
  always @(posedge mem_clk or negedge mem_rst_n)
   if(!mem_rst_n)compare_groups[comparison]<=0;
   else compare_groups[comparison]<=|compare_chunks[comparison*8+:8];
 end endgenerate
 wire [BITS-1:0] result_bus={status,version,packed_control,revision,visible_mask,coordinates};
 assign lease_ready=ack_sync==request_toggle;
 wire marker_index_valid;
 wire [31:0] header_index;
 assign read_valid=header_index<=6 || marker_index_valid;
 // Validity above checks the full request; only seven bits are needed for
 // the bounded 100-word marker table's quotient/remainder address decode.
 wire [6:0] relative_index=read_index[6:0]-7'd16;
 wire [4:0] marker_index;
 wire [2:0] marker_field;
 generate if(PREDECODE_READ)begin:g_read_predecode
  // Split the /5 address arithmetic from the 1280-bit snapshot selector.
  // The complete 32-bit range check rejects aliased high-bit addresses. A
  // displayed-frame update on the acceptance edge still reads the same live
  // state as the original interface; data is deliberately not pre-sampled.
  (* syn_preserve=1, syn_allow_retiming=0 *) reg [4:0] index_q;
  (* syn_preserve=1, syn_allow_retiming=0 *) reg [2:0] field_q,header_q;
  (* syn_preserve=1, syn_allow_retiming=0 *) reg valid_q;
  always @(posedge mem_clk or negedge mem_rst_n)
   if(!mem_rst_n)begin index_q<=0;field_q<=0;header_q<=7;valid_q<=0;end
   else begin
    index_q<=relative_index/5;field_q<=relative_index%5;
    header_q<=read_index<=6?read_index[2:0]:3'd7;
    valid_q<=read_index>=16 && read_index<116;
   end
  assign marker_index=index_q,marker_field=field_q,header_index={29'b0,header_q};
  assign marker_index_valid=valid_q;
 end else begin:g_read_combinational
  // Preserve the original zero-latency API for non-UART integrations/tests.
  assign marker_index=relative_index/5,marker_field=relative_index%5;
  assign header_index=read_index,marker_index_valid=read_index>=16 && read_index<116;
 end endgenerate
 wire [15:0] source_x,source_y;wire [23:0] source_color;
 geometry_marker_catalog u_catalog(marker_index,source_x,source_y,source_color);
 // Purpose: generation and all readback fields change together only after the
 // pixel domain confirms the first active raster of the selected leased frame.
 always @* begin
  read_value=0;
  case(header_index)
   0:read_value=32'h4d4b5231;1:read_value=applied_revision;
   2:read_value=applied_packed;3:read_value=applied_version;
   4:read_value={12'b0,snapshot[1299:1280]};5:read_value=generation;
   6:read_value=snapshot[1427:1396];
   default:if(marker_index_valid)case(marker_field)
    0:read_value={source_y,source_x};
    1:read_value=snapshot[marker_index*64+:32];
    2:read_value=snapshot[marker_index*64+32+:32];
    3:read_value={8'b0,source_color};
    4:read_value={31'b0,snapshot[1280+marker_index]};
   endcase
  endcase
 end
 integer k;
 always @(posedge mem_clk or negedge mem_rst_n)
 if(!mem_rst_n)begin
  request_toggle<=0;held_bus<=0;ack_meta<=0;ack_sync<=0;display_meta<=0;display_sync<=0;display_seen<=0;
  snapshot<=0;generation<=0;applied_revision<=0;applied_packed<=2560;applied_version<=0;metadata_changed<=0;
  for(k=0;k<3;k=k+1)slots[k]<=0;
 end else begin
  ack_meta<=pixel_ack_toggle;ack_sync<=ack_meta;display_meta<=display_toggle;display_sync<=display_meta;
  // Three comparison edges fit inside the held-bus request/ack/display round
  // trip. No extra pixel latency or changes to the CDC endpoints are required.
  metadata_changed<=|compare_groups;
  if(commit && result_slot<3)slots[result_slot]<=result_bus;
  // The framebuffer lease prevents replacement until pixel consumption ends.
  if(lease && lease_ready && lease_slot<3)begin held_bus<=slots[lease_slot];request_toggle<=!request_toggle;end
  if(display_sync!=display_seen)begin
   display_seen<=display_sync;
   // Metadata generations advance on a changed displayed configuration, not
   // identical repeated frames. A 100-word UART read can then finish at video
   // rates; model/config versions make these deterministic coordinates stable.
   if(generation==0 || metadata_changed)begin
    snapshot<=held_bus;generation<=generation+1'b1;
    applied_revision<=held_bus[1331:1300];applied_packed<=held_bus[1363:1332];applied_version<=held_bus[1395:1364];
   end
  end
 end
 always @(posedge pixel_clk or negedge pixel_rst_n)
 if(!pixel_rst_n)begin
  req_meta<=0;req_sync<=0;pixel_ack_toggle<=0;display_toggle<=0;pixel_pending<=0;
  frame_ack_meta<=0;frame_ack_sync<=0;previous_vs<=0;previous_request<=0;
  armed<=0;pending_valid<=0;await_display<=0;pixel_coordinates<=0;pixel_visible<=0;pixel_packed<=2560;
 end else begin
  req_meta<=request_toggle;req_sync<=req_meta;frame_ack_meta<=pixel_frame_ack;frame_ack_sync<=frame_ack_meta;
  previous_vs<=in_vs;previous_request<=pixel_request;
  // Two synchronizer stages precede sampling; source holds the entire bus
  // through acknowledgment AND until the framebuffer release handshake.
  if(req_sync!=pixel_ack_toggle)begin pixel_pending<=held_bus;pending_valid<=1;pixel_ack_toggle<=req_sync;end
  if(previous_request && !pixel_request && pending_valid)armed<=1;
  if(in_vs && !previous_vs && armed && !frame_ack_sync)begin
   pixel_coordinates<=pixel_pending[1279:0];pixel_visible<=pixel_pending[1299:1280];pixel_packed<=pixel_pending[1363:1332];
   armed<=0;pending_valid<=0;await_display<=1;
  end
  if(await_display && in_de)begin display_toggle<=!display_toggle;await_display<=0;end
 end
endmodule
