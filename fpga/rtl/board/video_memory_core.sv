`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: actual capture/ISP/frame-pool/geometry/RAW-network integration in
// the native 125 MHz DDR clock domain. Board wrappers supply atomic capture
// mailboxes and the pixel-domain display adapter. Processing throughput must
// be measured for this shared clock/bus; no 1080p30 timing claim is inferred.
module video_memory_core #(parameter WIDTH=1920,HEIGHT=1080,STATIC_ENDPOINTS=1,SUPPORT_CONTROLS=0,TONE_LUT_PREVALIDATED=0,
 // Board callers may consume the complete validated CONFIG digest instead
 // of retaining its parallel payload; direct-core compatibility stays default.
 parameter MCU_CONFIG_DIGEST_ONLY=0,
 // Enable only with the sole board UART uploader's streaming CCM proof.
 parameter CCM_PREVALIDATED=0,
 // Capacity-limited board profile retains manual ISP and preset tone curves.
 // Direct-core callers retain automatic loops and custom LUT by default.
 // PC-only board profile removes MCU pose and legacy motion diagnostics.
 // The source-owned geometry bank and job CDC remain authoritative.
 parameter PC_ONLY_CONTROL=0,
 parameter IMAGE_AUTOMATION=1,TONE_UPLOAD=1,SUPPORT_VIEWPORT=1)(
 input clk,rst_n,processing_clk,processing_rst_n,controller_ready,input [447:0] geometry_coefficients,input [1:0] enhancement,
 // Reference is a separately specified boot view, never inferred from ON.
 input [511:0] affine_reference,
 input reference_submit_valid,input [511:0] reference_entity,
 input [31:0] reference_version,reference_entity_id,output [7:0] reference_submit_code,
 output [767:0] reference_status,
 // Unified image entities are sampled only on validated commit.
 input motion_submit_valid,input [15:0] motion_kind,input [1023:0] motion_entity,
 input [31:0] motion_version,motion_id,output [7:0] motion_submit_code,
 input [15:0] motion_read_kind,output [2303:0] motion_status,
 input runtime_action_valid,input [15:0] runtime_action,runtime_action_seq,output [7:0] runtime_action_code,
 input mcu_enable,mcu_rx_valid,input [7:0] mcu_rx_data,input mcu_rx_error,
 output mcu_tx_valid,input mcu_tx_ready,output [7:0] mcu_tx_data,
 input mcu_timing_valid,input [31:0] mcu_capture_error,input mcu_config_approved,
 input [31:0] mcu_new_session,output mcu_config_valid,output [2111:0] mcu_config_entity,
 output [31:0] mcu_config_version,output [31:0] mcu_config_crc32,input mcu_config_ready,output mcu_reopen_required,
 output mcu_event_valid,output [319:0] mcu_event_payload,input mcu_event_ready,
 // Identity exports only; existing pose/frame datapath and timing are unchanged.
 output mcu_session_valid,mcu_mapping_valid,output [63:0] mcu_boot_id,
 input image_submit_valid,input [15:0] image_kind,input [2047:0] image_entity,
 input [31:0] image_version,image_id,output [7:0] image_submit_code,
 input [15:0] image_read_kind,output [2303:0] image_status,
 input [31:0] camera_config_version,input image_auto_stable,output camera_stats_valid,
 output [47:0] camera_stats_sum,output [31:0] camera_stats_count,
 input affine_submit_valid,input [15:0] affine_sequence,input [95:0] affine_payload,
 output [7:0] affine_submit_code,output reg [767:0] affine_status,
 input display_confirm_valid,input [63:0] display_confirm_epoch,display_confirm_frame,
 input [31:0] display_confirm_generation,
 input capture_valid,output capture_ready,output capture_complete,
 input mode_submit_valid,output mode_submit_ready,input [1:0] mode_submit,input [31:0] mode_version,
 input geometry_submit_valid,output geometry_submit_ready,input [543:0] geometry_submit,
 input [31:0] geometry_version,geometry_entity_id,output [767:0] geometry_status,
 output [767:0] control_status,
 input [63:0] capture_epoch,capture_id,capture_first,capture_last,
 input capture_end,capture_isp_legal,capture_raw_legal,input [31:0] capture_errors,
 input isp_abort,raw_abort,capture_queues_drained,
 input isp_byte_valid,output isp_byte_ready,input [7:0] isp_byte,
 input raw_byte_valid,output raw_byte_ready,input [7:0] raw_byte,
 input display_request,output display_offer_valid,input display_offer_ready,
 output [31:0] display_base,display_gen,output [1:0] display_slot,
 output [63:0] display_epoch,display_id,
 input display_release,input [1:0] display_release_slot,input [31:0] display_release_gen,
 output display_release_ready,
 input display_req_valid,output display_req_ready,input [31:0] display_req_addr,display_req_tag,
 input [4:0] display_req_beats,input display_cancel,display_urgent,
 output display_r_valid,input display_r_ready,output [255:0] display_r_data,output display_r_last,
 output display_done,input display_done_ready,output display_error,display_cancelled,output [31:0] display_done_tag,
 input [7:0] rx_data,input rx_dv,rx_er,input gigabit_link,
 input [47:0] network_local_mac,network_peer_mac,input [31:0] network_local_ip,network_peer_ip,
 input [15:0] network_local_port,network_peer_port,
 output [7:0] tx_data,output tx_en,tx_er,
 output fault,output [31:0] captured_frames,dropped_capture_frames,processed_frames,failed_processing_frames,
 output [27:0] awaddr,araddr,output [3:0] awlen,arlen,awid,arid,
 output awvalid,arvalid,input awready,arready,
 output [255:0] native_wdata,output [31:0] native_wstrb,input native_wready,native_wlast,input [3:0] native_wid,
 input [255:0] native_rdata,input native_rvalid,native_rlast,input [3:0] native_rid
);
 // Frame-atomic image entities retain source LUT generations and capture ISP
 // coefficients. Corrected S1 pixels never need reinterpretation by later ISP.
 wire [1:0] active_mode,capture_mode;
 wire [31:0] active_mode_version,capture_mode_version,capture_mode_entity;
 wire [63:0] mode_applied_epoch,mode_applied_frame;wire mode_pending;
 wire [7:0] tone_code,colour_code;wire [2303:0] tone_status,colour_status;
 wire [31:0] colour_capture_version,colour_black,capture_tone_generation;
 wire [63:0] colour_gains;wire [161:0] colour_ccm;
 reg [31:0] admitted_black;reg [63:0] admitted_gains;reg [161:0] admitted_ccm;
 reg [31:0] admitted_camera_version,admitted_colour_version;
 reg [31:0] source_camera_version[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 reg admitted_tone_page;reg [31:0] admitted_tone_generation;
 reg [31:0] source_tone_generation[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 wire capture_tone_page,tone_programming,tone_initialized;
 wire tone_loading,tone_commit,tone_write_page;wire [7:0] tone_address,tone_value;wire [31:0] tone_program_version;
 wire good_statistics=capture_complete && cap_isp && last_statistics_id==capture_id &&
  !last_statistics_failed && capture_isp_legal && !isp_writer_failed && !isp_error;
 // Ignore a completed source captured under the prior camera configuration
 // when advancing exposure settling or any image loop. History retains its
 // original statistics independently through good_statistics below.
 wire current_camera_statistics=good_statistics && admitted_camera_version==camera_config_version;
 assign camera_stats_valid=current_camera_statistics,camera_stats_sum=last_statistics_sum,camera_stats_count=last_statistics_samples;
 wire [47:0] awb_red,awb_green,awb_blue;wire [31:0] awb_neutrals;
 assign image_submit_code=image_kind==3?colour_code:((image_kind==1 || image_kind==2)?tone_code:8'd6);
 assign image_status=image_read_kind==3?colour_status:tone_status;
 isp_colour_control #(.SUPPORT_AUTO(IMAGE_AUTOMATION),.CCM_PREVALIDATED(CCM_PREVALIDATED)) colour_control(.clk(clk),.rst_n(rst_n),.submit_valid(SUPPORT_CONTROLS && image_submit_valid && image_kind==3),
  .body(image_entity[511:0]),.version(image_version),.entity_id(image_id),.submit_code(colour_code),
  .capture_boundary(capture_valid && capture_ready),.epoch(capture_epoch),.frame_id(capture_id),
  .capture_version(colour_capture_version),.capture_black(colour_black),.capture_gains(colour_gains),.capture_ccm(colour_ccm),
  .statistics_valid(current_camera_statistics && image_auto_stable),.red_sum(awb_red),.green_sum(awb_green),.blue_sum(awb_blue),.neutral_count(awb_neutrals),.status(colour_status));
 // Default direct-core callers validate the entire LUT. Only the physical
 // board's single CRC/monotonic UART gateway may select prevalidated input.
 tone_entity_control #(.LUT_PREVALIDATED(TONE_LUT_PREVALIDATED),.SUPPORT_AUTO(IMAGE_AUTOMATION),.SUPPORT_UPLOAD(TONE_UPLOAD)) tone_control(.clk(clk),.rst_n(rst_n),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),
  .submit_valid(SUPPORT_CONTROLS && image_submit_valid && (image_kind==1 || image_kind==2)),.kind(image_kind),.body(image_entity),
  .version(image_version),.entity_id(image_id),.submit_code(tone_code),.read_kind(image_read_kind==2?16'd2:16'd1),.status(tone_status),
  .legacy_valid(SUPPORT_CONTROLS && mode_submit_valid),.legacy_mode(mode_submit),.legacy_version(mode_version),.legacy_ready(mode_submit_ready),
  .capture_boundary(capture_valid && capture_ready),.epoch(capture_epoch),.frame_id(capture_id),.capture_mode(capture_mode),
  .capture_version(capture_mode_version),.capture_entity_id(capture_mode_entity),.capture_lut_version(capture_tone_generation),.capture_page(capture_tone_page),
  .current_mode(active_mode),.current_version(active_mode_version),.current_pending(mode_pending),.current_epoch(mode_applied_epoch),.current_frame(mode_applied_frame),
  .bind_valid(cap_start && cap_isp),.bind_slot(src_slot),.bind_page(admitted_tone_page),
  .release_valid(geo_done),.release_slot(geo_src_slot),
  .cancel_valid(capture_complete && cap_isp && (!capture_isp_legal || isp_writer_failed || isp_error)),.cancel_slot(src_slot),
  .geometry_idle(mailbox_ready),.programming(tone_programming),.initialized(tone_initialized),
  .statistics_valid(current_camera_statistics && image_auto_stable),.luminance_sum(last_statistics_sum),.samples(last_statistics_samples),
  .lut_write(tone_loading),.lut_addr(tone_address),.lut_data(tone_value),.lut_commit(tone_commit),.lut_page(tone_write_page),.lut_program_version(tone_program_version));
 integer image_slot;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   admitted_colour_version<=1;admitted_camera_version<=1;
   admitted_black<=0;admitted_gains<=64'h1000100010001000;admitted_ccm<=162'd16384|(162'd16384<<72)|(162'd16384<<144);
   admitted_tone_page<=0;admitted_tone_generation<=1;
  end else begin
   if(capture_valid && capture_ready)begin
    // Freeze the same ISP version as SRC metadata and coefficients. A submit
    // on this edge only queues the next source and must not relabel this one.
    admitted_colour_version<=colour_capture_version;admitted_camera_version<=camera_config_version;
    admitted_black<=colour_black;admitted_gains<=colour_gains;admitted_ccm<=colour_ccm;
    admitted_tone_page<=capture_tone_page;admitted_tone_generation<=capture_tone_generation;
   end
  end
 end
 // Source payload is written on slot allocation before any sealed PROCESS or
 // HISTORY owner may read it. Resetting ownership is sufficient; clock-only
 // payload permits shallow distributed RAM instead of resettable muxed FFs.
 always @(posedge clk)begin
  if(rst_n && cap_start && cap_isp)begin
   source_tone_generation[src_slot]<=admitted_tone_generation;
   source_camera_version[src_slot]<=admitted_camera_version;
  end
 end
 // A whole affine/lens entity commits on the source boundary.
 // Each of the three SRC slots retains its own coefficients until PROCESS
 // retires. A later PC update cannot reinterpret an older queued source.
 reg geometry_seeded;wire geometry_bank_ready,geometry_pending;
 wire [447:0] active_geometry,capture_geometry;
 wire [31:0] active_geometry_version,active_geometry_id,capture_geometry_version,capture_geometry_id;
 wire [63:0] geometry_applied_epoch,geometry_applied_frame;
 wire geometry_seed_request=SUPPORT_CONTROLS && !geometry_seeded;
 assign geometry_submit_ready=SUPPORT_CONTROLS && geometry_seeded && geometry_bank_ready && !affine_pending && !reference_pending;
 frame_parameter_bank #(.ENTITY_BITS(448)) geometries(.clk(clk),.rst_n(rst_n),
  .submit_valid(geometry_seed_request || (SUPPORT_CONTROLS && geometry_submit_valid)),.submit_ready(geometry_bank_ready),
  .entity_validated(1'b1),.entity(geometry_seed_request?geometry_coefficients:geometry_submit[447:0]),
  .version(geometry_seed_request?32'd1:geometry_version),.entity_id(geometry_seed_request?32'd1:geometry_entity_id),
  .received(),.validated(),.rejected(),.capture_boundary(capture_valid && capture_ready),.epoch(capture_epoch),.frame_id(capture_id),
  .active_entity(active_geometry),.active_version(active_geometry_version),.active_entity_id(active_geometry_id),
  .capture_entity(capture_geometry),.capture_version(capture_geometry_version),.capture_entity_id(capture_geometry_id),
  .applied(),.applied_ready(1'b1),.applied_epoch(geometry_applied_epoch),.applied_frame(geometry_applied_frame),.pending(geometry_pending));
 assign geometry_status={8'h47,16'd0,7'd0,geometry_pending,geometry_applied_frame,geometry_applied_epoch,
  active_geometry_version,active_geometry_id,32'h04000000,64'd0,active_geometry};
 reg [447:0] source_geometry[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 reg [447:0] admitted_geometry;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin geometry_seeded<=0;admitted_geometry<=0;end
  else begin
   if(geometry_seed_request && geometry_bank_ready)geometry_seeded<=1;
   if(capture_valid && capture_ready)admitted_geometry<=SUPPORT_CONTROLS?selected_capture_geometry:geometry_coefficients;
  end
 end
 // A single dynamic write/read pair permits distributed RAM inference under
 // the installed ADS syn_ramstyle attribute. geo_src_slot is owned after this write and
 // successful seal, so uninitialized free-slot data cannot enter a job.
 always @(posedge clk)
  if(rst_n && cap_start && cap_isp)source_geometry[src_slot]<=admitted_geometry;
 // Reference has an independent versioned entity and the same bounded
 // geometry/control arbitration. Entire output K and normalized matrix publish
 // together; source slots retain the chosen matrix and reference version.
 reg reference_seeded;wire reference_bank_ready,reference_pending,reference_legal,reference_validation_valid;
 wire [511:0] reference_active,reference_capture;
 wire [31:0] reference_active_version,reference_active_id,reference_capture_version;
 wire [63:0] reference_epoch,reference_frame;
 wire reference_seed=SUPPORT_CONTROLS && !reference_seeded;
 wire [511:0] checked_reference=reference_seed?affine_reference:reference_entity;
 // Only a legal raw entity may enter the bank. Expose its proven constant
 // fields explicitly after sequential validation so synthesis can still prune
 // reserved/axis/dimension storage in both shadow and active reference copies.
 // The guard always inspects checked_reference, including malformed fields.
 wire [511:0] canonical_reference={112'd0,16'd1,checked_reference[383:352],HEIGHT[15:0],WIDTH[15:0],
                                 checked_reference[319:256],32'd0,checked_reference[223:192],32'd0,checked_reference[159:0]};
 // Freeze and validate through a serial partial-product engine; the internal
 // 0xff token holds kind9 COMMIT until this exact body has a completed result.
 affine_reference_guard #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIPELINED(1)) reference_guard(
  .clk(clk),.rst_n(rst_n),.entity(checked_reference),.legal(reference_legal),.result_valid(reference_validation_valid));
 assign reference_submit_code=!reference_validation_valid?8'hff:!reference_legal || reference_version==0 || reference_version[31] ||
   reference_entity_id==0 || reference_entity_id[31] || reference_version<=reference_active_version ? 8'd11:
   (!reference_seeded || !reference_bank_ready || geometry_pending || affine_pending)?8'd4:8'd0;
 frame_parameter_bank #(.ENTITY_BITS(512)) references(.clk(clk),.rst_n(rst_n),
  .submit_valid((reference_seed && reference_validation_valid) || (reference_submit_valid && reference_submit_code==0)),
  .submit_ready(reference_bank_ready),.entity_validated(reference_legal),.entity(canonical_reference),
  .version(reference_seed?32'd1:reference_version),.entity_id(reference_seed?32'd1:reference_entity_id),
  .received(),.validated(),.rejected(),.capture_boundary(capture_valid && capture_ready),
  .epoch(capture_epoch),.frame_id(capture_id),.active_entity(reference_active),
  .active_version(reference_active_version),.active_entity_id(reference_active_id),
  .capture_entity(reference_capture),.capture_version(reference_capture_version),.capture_entity_id(),
  .applied(),.applied_ready(1'b1),.applied_epoch(reference_epoch),.applied_frame(reference_frame),.pending(reference_pending));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)reference_seeded<=0;
  else if(reference_seed && reference_bank_ready && reference_legal)reference_seeded<=1;
 end
 assign reference_status={56'd0,7'd0,reference_pending,reference_frame,reference_epoch,
                          reference_active_id,reference_active_version,reference_active};
 // Select ON/OFF once per admitted source, before slot allocation completes.
 // The normal per-slot geometry bus and job mailbox carry that actual matrix.
 wire affine_pending,affine_enabled,affine_requested,affine_capture_enable;
 wire [447:0] selected_capture_geometry;
 wire [31:0] affine_version,affine_requested_version,affine_capture_version;
 wire [63:0] affine_epoch,affine_frame;wire [191:0] affine_coefficients;
 affine_frame_control affine_control(.clk(clk),.rst_n(rst_n),
  .submit_valid(SUPPORT_CONTROLS && affine_submit_valid),.submit_sequence(affine_sequence),
  .submit_payload(affine_payload),.submit_code(affine_submit_code),
  .other_pending(geometry_pending || reference_pending || !reference_seeded),.geometry_version(active_geometry_version),
  .capture_geometry(capture_geometry),.reference_coefficients(reference_capture[128+:192]),
  .capture_boundary(capture_valid && capture_ready),.capture_epoch(capture_epoch),.capture_frame(capture_id),
  .capture_coefficients(selected_capture_geometry),.capture_enable(affine_capture_enable),
  .capture_control_version(affine_capture_version),.pending(affine_pending),
  .applied_enable(affine_enabled),.requested_enable(affine_requested),
  .control_version(affine_version),.requested_version(affine_requested_version),
  .applied_epoch(affine_epoch),.applied_frame(affine_frame),.applied_coefficients(affine_coefficients));
 // Sidecars are indexed by owned slots and copied with their exact generation.
 // Display confirmation comes from the pixel-domain adopted descriptor; offer
 // acceptance alone is deliberately insufficient to claim visible application.
 reg [64:0] source_affine[0:2],admitted_affine;
 reg [96:0] result_affine[0:2];
 reg [31:0] result_affine_generation[0:2];
 reg [127:0] result_affine_identity[0:2];
 reg display_affine_known;reg [96:0] displayed_affine;
 reg [127:0] displayed_identity;
 integer affine_slot;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   admitted_affine<=0;display_affine_known<=0;displayed_affine<=0;displayed_identity<=0;
   for(affine_slot=0;affine_slot<3;affine_slot=affine_slot+1)begin
    source_affine[affine_slot]<=0;result_affine[affine_slot]<=0;
    result_affine_generation[affine_slot]<=0;result_affine_identity[affine_slot]<=0;
   end
  end else begin
   if(capture_valid && capture_ready)admitted_affine<={reference_capture_version,affine_capture_version,affine_capture_enable};
   // Constant destination indices share one slot enable rather than a wide
   // variable-index write/merge network. All identity/generation bits retain
   // their original reset and commit edge for display confirmation checks.
   for(affine_slot=0;affine_slot<3;affine_slot=affine_slot+1)begin
    if(cap_start && cap_isp && src_slot==affine_slot)source_affine[affine_slot]<=admitted_affine;
    if(geo_valid && geo_ready && geo_dst_slot==affine_slot)begin
     result_affine[affine_slot]<={source_affine[geo_src_slot][64:33],processor_meta.geometry_version,source_affine[geo_src_slot][32:0]};
     result_affine_generation[affine_slot]<=geo_dst_gen;
     result_affine_identity[affine_slot]<={processor_meta.epoch,processor_meta.frame_id};
    end
   end
   if(display_confirm_valid)begin
    display_affine_known<=0;
    for(affine_slot=0;affine_slot<3;affine_slot=affine_slot+1)begin
     if(result_affine_generation[affine_slot]==display_confirm_generation &&
        result_affine_identity[affine_slot]=={display_confirm_epoch,display_confirm_frame} &&
        display_confirm_generation!=0)begin
      display_affine_known<=1;displayed_affine<=result_affine[affine_slot];
      displayed_identity<={display_confirm_epoch,display_confirm_frame};
     end
    end
   end
  end
 end
 // AFG1 entity 10, schema 1. Unverified HDMI capture-card callbacks are never
 // used here; these fields report only the board's own scanout descriptor.
 always @*begin
  affine_status=0;affine_status[15:0]=1;affine_status[31:16]=10;
  affine_status[32]=affine_requested;affine_status[33]=affine_enabled;
  affine_status[34]=affine_pending;affine_status[35]=display_affine_known;
  affine_status[64+:32]=affine_version;affine_status[96+:32]=active_geometry_version;
  affine_status[128+:32]=reference_active_version;affine_status[160+:32]=affine_requested_version;
  affine_status[192+:64]=affine_epoch;affine_status[256+:64]=affine_frame;
  affine_status[320+:192]=affine_coefficients;
  affine_status[512+:64]=displayed_identity[127:64];affine_status[576+:64]=displayed_identity[63:0];
  affine_status[640+:32]=displayed_affine[32:1];affine_status[672+:32]=displayed_affine[64:33];
  affine_status[704+:32]=displayed_affine[96:65];affine_status[736]=displayed_affine[0];
 end
 wire [3*CMD_BITS-1:0] command,scheduler_command;wire [3*RSP_BITS-1:0] response;
 wire [5:0] req_valid,req_ready,w_valid,w_ready,r_valid,r_ready,r_last,done,done_ready,error,cancelled,cancel;
 wire [191:0] req_addr,req_tag,req_generation,done_tag,w_strb;
 wire [29:0] req_beats;wire [17:0] req_bank,req_owner;wire [11:0] req_slot;
 wire [1535:0] w_data,r_data;
 wire cap_start,cap_isp,cap_raw;
 wire [31:0] src_base,src_gen,raw_base,raw_gen;wire [1:0] src_slot,raw_slot;
 wire isp_writer_done,isp_writer_failed,raw_writer_done,raw_writer_failed;
 wire [31:0] geo_src_base,geo_src_gen,geo_dst_base,geo_dst_gen;wire [1:0] geo_src_slot,geo_dst_slot;
 wire geo_valid,geo_ready,geo_done,geo_failed;
 wire [META_BITS-1:0] geo_metadata,display_metadata,export_metadata;
 wire export_ready,export_valid,export_release,export_release_ready;
 wire [31:0] export_base,export_gen;wire [1:0] export_slot;
 frame_meta_t capture_meta,display_meta,export_meta;
 assign display_meta=display_metadata,export_meta=export_metadata;
 assign display_epoch=display_meta.epoch,display_id=display_meta.frame_id;
 always @*begin
  capture_meta='0;capture_meta.epoch=capture_epoch;capture_meta.frame_id=capture_id;
  capture_meta.capture_first=capture_first;capture_meta.width=WIDTH;capture_meta.height=HEIGHT;
  capture_meta.isp_version=colour_capture_version;capture_meta.geometry_version=SUPPORT_CONTROLS?capture_geometry_version:1;capture_meta.enhancement_version=SUPPORT_CONTROLS?capture_mode_version:1;
  capture_meta.calibration_entity=SUPPORT_CONTROLS?capture_geometry_id:1;capture_meta.parameter_entity=SUPPORT_CONTROLS?capture_mode_entity:1;capture_meta.enhancement_stage=SUPPORT_CONTROLS?capture_mode:enhancement;
  // Capture metadata precedes asynchronous pose selection. The processing
  // result/kind11 record carries the actual selected MCU/manual pose status.
  capture_meta.mode=SUPPORT_CONTROLS?capture_mode:enhancement;// PC-only has no measured pose: report disabled.
  capture_meta.pose_status=PC_ONLY_CONTROL?3:1;
 end
 // One genuine S1 history reference is owned by the scheduler. Statistics
 // sidecars remain protected by that same slot generation until DMA drains.
 wire history_capture_enable,history_clear,history_valid,history_registration_ok;
 wire [1:0] history_slot;wire [31:0] history_gen,history_base,history_skipped;
 wire [META_BITS-1:0] history_metadata;frame_meta_t history_meta;
 assign history_meta=history_metadata;
 reg [47:0] source_luma_sum[0:2];reg [31:0] source_luma_count[0:2];integer luma_slot;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)for(luma_slot=0;luma_slot<3;luma_slot=luma_slot+1)begin source_luma_sum[luma_slot]<=0;source_luma_count[luma_slot]<=0;end
  else if(good_statistics)begin source_luma_sum[src_slot]<=last_statistics_sum;source_luma_count[src_slot]<=last_statistics_samples;end
 end
 wire [47:0] history_luma_delta=source_luma_sum[geo_src_slot]>=source_luma_sum[history_slot]?
  source_luma_sum[geo_src_slot]-source_luma_sum[history_slot]:source_luma_sum[history_slot]-source_luma_sum[geo_src_slot];
 wire history_eligible=source_camera_version[geo_src_slot]==source_camera_version[history_slot] && history_valid && completion_job_config[0] && source_affine[geo_src_slot][0] && history_registration_ok &&
  source_luma_count[geo_src_slot]!=0 && source_luma_count[geo_src_slot]==source_luma_count[history_slot] &&
  history_luma_delta<=completion_job_config[47:32]*source_luma_count[geo_src_slot] &&
  motion_job_confidence>=completion_job_config[31:16] && motion_registration_version==completion_job_config[95:64] &&
  history_meta.epoch==processor_meta.epoch && processor_meta.frame_id>history_meta.frame_id &&
  processor_meta.frame_id-history_meta.frame_id<=completion_job_config[15:8];
 reg [31:0] held_history_base,held_history_gen;reg [1:0] held_history_slot;
 wire source_history;wire [31:0] current_pixel_count,history_pixel_count,invalid_pixel_count;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin held_history_base<=0;held_history_gen<=0;held_history_slot<=0;end
  else if(geo_valid && geo_ready)begin held_history_base<=history_base;held_history_gen<=history_gen;held_history_slot<=history_slot;end
 end
 // OFF also needs the validated boot reference. Hold initial admission until
 // its sequential guard has queued the seed; later frames never wait here.
 video_frame_scheduler scheduler(.clk(clk),.rst_n(rst_n),.fabric_ready(controller_ready && !fault && (!SUPPORT_CONTROLS || reference_seeded)),
  .response(response),.command(scheduler_command),
  .history_capture_enable(history_capture_enable),.history_clear(history_clear),.history_valid(history_valid),.history_slot(history_slot),
  .history_gen(history_gen),.history_base(history_base),.history_skipped(history_skipped),.history_metadata(history_metadata),
  .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_metadata(capture_meta),
  .capture_end(capture_end),.capture_isp_legal(capture_isp_legal),.capture_raw_legal(capture_raw_legal),
  .capture_last(capture_last),.capture_errors(capture_errors),.capture_queues_drained(capture_queues_drained),
  .capture_complete(capture_complete),.capture_start(cap_start),.capture_isp(cap_isp),.capture_raw(cap_raw),
  .capture_src_base(src_base),.capture_src_gen(src_gen),.capture_raw_base(raw_base),.capture_raw_gen(raw_gen),
  .capture_src_slot(src_slot),.capture_raw_slot(raw_slot),.isp_done(isp_writer_done),.isp_failed(isp_writer_failed),
  .raw_done(raw_writer_done),.raw_failed(raw_writer_failed),.geometry_valid(geo_valid),.geometry_ready(geo_ready),
  .geometry_done(geo_done),.geometry_failed(geo_failed),.geometry_source_base(geo_src_base),.geometry_source_gen(geo_src_gen),
  .geometry_result_base(geo_dst_base),.geometry_result_gen(geo_dst_gen),.geometry_source_slot(geo_src_slot),
  .geometry_result_slot(geo_dst_slot),.geometry_metadata(geo_metadata),.raw_export_ready(export_ready),
  .raw_export_valid(export_valid),.raw_export_release(export_release),.raw_export_release_ready(export_release_ready),
  .raw_export_metadata(export_metadata),.raw_export_base(export_base),.raw_export_gen(export_gen),.raw_export_slot(export_slot),
  .display_request(display_request),.display_offer_valid(display_offer_valid),.display_offer_ready(display_offer_ready),
  .display_metadata(display_metadata),.display_base(display_base),.display_gen(display_gen),.display_slot(display_slot),
  .display_release(display_release),.display_release_slot(display_release_slot),.display_release_gen(display_release_gen),
  .display_release_ready(display_release_ready),.captured_frames(captured_frames),.dropped_capture_frames(dropped_capture_frames),
  .processed_frames(processed_frames),.failed_processing_frames(failed_processing_frames));

 // Capture queues carry bytes, with position reconstructed only after an
 // immutable admitted context starts. Aborted/unallocated branches discard
 // their remaining bytes without feeding an idle writer or the next frame.
 reg cap_live,isp_input_finished,raw_input_finished,isp_output_finished;
 reg [15:0] ix,iy,rx,ry;
 wire isp_in_ready,isp_frame_ready,isp_out_valid,isp_out_ready,isp_out_last,isp_out_mask,isp_error;
 wire [23:0] isp_rgb;wire [15:0] isp_x,isp_y;
 wire [35:0] isp_linear;
 wire isp_pixel_ready,isp_writer_ready,raw_pixel_ready,raw_writer_ready;
 wire ccm_ready,ccm_valid,ccm_mask,ccm_output_ready;wire [23:0] ccm_rgb;wire [31:0] ccm_coordinates;
 localparam [161:0] IDENTITY_CCM=(162'd16384 | (162'd16384<<72) | (162'd16384<<144));
 wire isp_abort_now=cap_live && (isp_abort || (capture_end && !capture_isp_legal) || isp_writer_failed);
 wire raw_abort_now=cap_live && (raw_abort || (capture_end && !capture_raw_legal));
 assign isp_byte_ready=cap_live && (isp_abort_now || !cap_isp || isp_input_finished || isp_in_ready);
 assign raw_byte_ready=cap_live && (raw_abort_now || !cap_raw || raw_input_finished || raw_pixel_ready);
 wire isp_accept=isp_byte_valid && isp_byte_ready && cap_isp && !isp_input_finished && !isp_abort_now;
 wire raw_accept=raw_byte_valid && raw_byte_ready && cap_raw && !raw_input_finished && !raw_abort_now;
 assign isp_out_ready=isp_output_finished || isp_writer_failed || ccm_ready;
 assign ccm_output_ready=isp_output_finished || isp_writer_failed || isp_pixel_ready;
 rgb_colour_matrix #(.TAG_BITS(32)) colour(.clk(clk),.rst_n(rst_n && !isp_abort_now),
  .in_valid(isp_out_valid && !isp_output_finished && !isp_writer_failed),.in_ready(ccm_ready),.in_rgb(isp_linear),
  .coefficients(admitted_ccm),.in_tag({isp_y,isp_x}),.in_mask(isp_out_mask),
  .out_valid(ccm_valid),.out_ready(ccm_output_ready),.out_rgb(ccm_rgb),.out_mask(ccm_mask),.out_tag(ccm_coordinates));
 wire statistics_valid,statistics_failed;wire [63:0] statistics_id;wire [47:0] statistics_sum;
 wire [31:0] statistics_samples,statistics_dark,statistics_saturated;
 reg [63:0] last_statistics_id;reg [47:0] last_statistics_sum;
 reg [31:0] last_statistics_samples,last_statistics_dark,last_statistics_saturated;
 reg last_statistics_valid,last_statistics_failed;
 // Manual-only builds have no AWB consumer, so omit its private accumulators.
 generate if(IMAGE_AUTOMATION)begin: automatic_white_statistics
 // Pre-CCM neutral statistics keep color-matrix calibration outside AWB feedback.
 rgb_frame_statistics #(.TAG_BITS(64),.SUPPORT_ABORT(1)) white_statistics(.clk(clk),.rst_n(rst_n),
  .frame_start(cap_start && cap_isp),.frame_tag(capture_id),.frame_abort(isp_abort_now || isp_error),.result_failed(),
  .roi_x(16'd0),.roi_y(16'd0),.roi_width(WIDTH[15:0]),.roi_height(HEIGHT[15:0]),
  .pixel_valid(isp_out_valid),.pixel_ready(isp_out_ready),.pixel_mask(isp_out_mask),.pixel_last(isp_out_last),
  .pixel_x(isp_x),.pixel_y(isp_y),.pixel_rgb(isp_rgb),.result_valid(),.result_ready(1'b1),.result_tag(),
  .luminance_sum(),.samples(),.dark(),.saturated(),.red_sum(awb_red),.green_sum(awb_green),.blue_sum(awb_blue),.neutral_count(awb_neutrals),.rejected());
 end else begin: manual_white_statistics
  assign awb_red=0,awb_green=0,awb_blue=0,awb_neutrals=0;
 end endgenerate
 rgb_frame_statistics #(.TAG_BITS(64),.SUPPORT_ABORT(1)) statistics(.clk(clk),.rst_n(rst_n),.frame_start(cap_start && cap_isp),
  .frame_tag(capture_id),.frame_abort(isp_abort_now || isp_error),.result_failed(statistics_failed),
  .roi_x(16'd0),.roi_y(16'd0),.roi_width(WIDTH[15:0]),.roi_height(HEIGHT[15:0]),
  .pixel_valid(ccm_valid),.pixel_ready(ccm_output_ready),.pixel_mask(ccm_mask),
  .pixel_last(ccm_coordinates[15:0]==WIDTH-1 && ccm_coordinates[31:16]==HEIGHT-1),
  .pixel_x(ccm_coordinates[15:0]),.pixel_y(ccm_coordinates[31:16]),.pixel_rgb(ccm_rgb),
  .result_valid(statistics_valid),.result_ready(1'b1),.result_tag(statistics_id),.luminance_sum(statistics_sum),
  .samples(statistics_samples),.dark(statistics_dark),.saturated(statistics_saturated),.rejected());
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin last_statistics_id<=0;last_statistics_sum<=0;last_statistics_samples<=0;last_statistics_dark<=0;
   last_statistics_saturated<=0;last_statistics_valid<=0;last_statistics_failed<=0;end
  else begin
   if(cap_start && cap_isp)last_statistics_valid<=0;
   if(statistics_valid)begin last_statistics_id<=statistics_id;last_statistics_sum<=statistics_sum;
   last_statistics_samples<=statistics_samples;last_statistics_dark<=statistics_dark;last_statistics_saturated<=statistics_saturated;
   last_statistics_failed<=statistics_failed;end
   // A complete S1 tap is not measurement-ready before legal EOF and the
   // writer fence. Late long-line/EOF errors mark its saved statistics failed.
   if(capture_complete && cap_isp && last_statistics_id==capture_id)begin
    last_statistics_valid<=1;last_statistics_failed<=last_statistics_failed || !capture_isp_legal || isp_writer_failed || isp_error;
   end
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin cap_live<=0;ix<=0;iy<=0;rx<=0;ry<=0;isp_input_finished<=0;raw_input_finished<=0;isp_output_finished<=0;end
  else begin
   // Do not dequeue any bytes between context acceptance and writer start.
   // A previous job's sticky failed flag is cleared by that start edge.
   if(cap_start)begin cap_live<=1;ix<=0;iy<=0;rx<=0;ry<=0;isp_input_finished<=0;raw_input_finished<=0;isp_output_finished<=0;end
   if(isp_accept)begin
    if(ix==WIDTH-1)begin ix<=0;iy<=iy+1'b1;if(iy==HEIGHT-1)isp_input_finished<=1;end else ix<=ix+1'b1;
   end
   if(raw_accept)begin
    if(rx==WIDTH-1)begin rx<=0;ry<=ry+1'b1;if(ry==HEIGHT-1)raw_input_finished<=1;end else rx<=rx+1'b1;
   end
   if(isp_writer_done)isp_output_finished<=1;
   if(capture_complete)cap_live<=0;
  end
 end
 raw8_isp #(.TAG_BITS(META_BITS)) isp(.clk(clk),.rst_n(rst_n),.frame_start(cap_start && cap_isp),.frame_ready(isp_frame_ready),
  .frame_width(WIDTH[15:0]),.frame_height(HEIGHT[15:0]),.frame_bayer(2'd3),.black_levels(admitted_black),
  .colour_gains(admitted_gains),.frame_tag(capture_meta),.frame_abort(isp_abort_now),
  .in_valid(isp_accept),.in_ready(isp_in_ready),.in_raw(isp_byte),.in_sof(ix==0 && iy==0),.in_eol(ix==WIDTH-1),
  .out_valid(isp_out_valid),.out_ready(isp_out_ready),.out_rgb(isp_rgb),.out_linear_rgb(isp_linear),
  .out_x(isp_x),.out_y(isp_y),.out_sof(),.out_eol(),.out_last(isp_out_last),.out_mask(isp_out_mask),.out_tag(),.frame_error(isp_error),.config_rejected());
 frame_writer_buffer isp_writer(.clk(clk),.rst_n(rst_n),.frame_valid(cap_start && cap_isp),.frame_ready(isp_writer_ready),
  .frame_base(src_base),.frame_stride(32'd6144),.frame_generation(src_gen),.frame_width(WIDTH[15:0]),.frame_height(HEIGHT[15:0]),
  .frame_rgb888(1'b1),.frame_abort(isp_abort_now || isp_error),.in_valid(ccm_valid && !isp_output_finished),
  .in_ready(isp_pixel_ready),.in_pixel(ccm_mask?ccm_rgb:24'd0),.in_x(ccm_coordinates[15:0]),.in_y(ccm_coordinates[31:16]),
  .frame_done(isp_writer_done),.frame_failed(isp_writer_failed),.accepted_pixels(),
  .req_valid(req_valid[1]),.req_ready(req_ready[1]),.req_write(),.req_addr(req_addr[32+:32]),.req_tag(req_tag[32+:32]),.req_beats(req_beats[5+:5]),
  .w_valid(w_valid[1]),.w_ready(w_ready[1]),.w_data(w_data[256+:256]),.w_strb(w_strb[32+:32]),.dma_cancel(cancel[1]),
  .done(done[1]),.done_ready(done_ready[1]),.dma_error(error[1]),.dma_cancelled(cancelled[1]),.done_tag(done_tag[32+:32]));
 frame_writer_buffer raw_writer(.clk(clk),.rst_n(rst_n),.frame_valid(cap_start && cap_raw),.frame_ready(raw_writer_ready),
  .frame_base(raw_base),.frame_stride(32'd2048),.frame_generation(raw_gen),.frame_width(WIDTH[15:0]),.frame_height(HEIGHT[15:0]),
  .frame_rgb888(1'b0),.frame_abort(raw_abort_now),.in_valid(raw_accept),.in_ready(raw_pixel_ready),
  .in_pixel({16'd0,raw_byte}),.in_x(rx),.in_y(ry),.frame_done(raw_writer_done),.frame_failed(raw_writer_failed),.accepted_pixels(),
  .req_valid(req_valid[0]),.req_ready(req_ready[0]),.req_write(),.req_addr(req_addr[0+:32]),.req_tag(req_tag[0+:32]),.req_beats(req_beats[0+:5]),
  .w_valid(w_valid[0]),.w_ready(w_ready[0]),.w_data(w_data[0+:256]),.w_strb(w_strb[0+:32]),.dma_cancel(cancel[0]),
  .done(done[0]),.done_ready(done_ready[0]),.dma_error(error[0]),.dma_cancelled(cancelled[0]),.done_tag(done_tag[0+:32]));
 // Block geometry, not DVP, while a full replicated page is programmed.
 wire tone_ready_ddr=tone_initialized && !tone_programming;
 // C3 pose and C6 fixed crop run in DDR domain; C4 is disabled. The matrix
 // enters the existing job mailbox; capture never waits for this calculation.
 wire motion_prepared;wire [447:0] motion_geometry;wire [3:0] motion_pose_state,motion_visual_state;
 wire [127:0] completion_job_config;wire [31:0] motion_registration_version;wire [127:0] motion_entity_versions;
 wire signed [31:0] motion_job_dx,motion_job_dy;wire [15:0] motion_job_confidence;
 wire [2303:0] motion_entity_status;wire [31:0] motion_missed;
 generate if(PC_ONLY_CONTROL)begin: pc_only_control
  // Scheduler holds source ownership until job acceptance/completion. Pass
  // its frozen PC matrix directly into the existing job mailbox; no current
  // live configuration or asynchronously received pose can alter this frame.
  assign motion_prepared=1'b1,motion_geometry=source_geometry[geo_src_slot];
  assign motion_pose_state=4'd3,motion_visual_state=4'd8,motion_missed=0;
  assign motion_submit_code=8'd6,runtime_action_code=8'd6,motion_status=0;
  assign completion_job_config=0,motion_registration_version=0,motion_entity_versions=0;
  assign motion_job_dx=0,motion_job_dy=0,motion_job_confidence=0;
  assign history_capture_enable=1'b0,history_clear=1'b0,history_registration_ok=1'b0;
  assign mcu_tx_valid=0,mcu_tx_data=0,mcu_config_valid=0,mcu_config_entity=0;
  assign mcu_config_version=0,mcu_config_crc32=0,mcu_reopen_required=0;
  assign mcu_event_valid=0,mcu_event_payload=0,mcu_session_valid=0,mcu_mapping_valid=0,mcu_boot_id=0;
 end else begin: legacy_motion_control
 // Discrete actions queue independently of entity uploads and execute only
 // at a source boundary. They never clear an in-flight DMA/ownership machine.
 wire runtime_motion_reset,runtime_history_clear;wire [319:0] runtime_action_status;
 frame_runtime_actions runtime_actions(.clk(clk),.rst_n(rst_n),.submit_valid(SUPPORT_CONTROLS && runtime_action_valid),
  .action(runtime_action),.request_seq(runtime_action_seq),.submit_code(runtime_action_code),
  .capture_boundary(capture_valid && capture_ready),.epoch(capture_epoch),.frame_id(capture_id),
  .clear_motion(runtime_motion_reset),.clear_history(runtime_history_clear),.status_extension(runtime_action_status));
 // The capacity profile omits the separate viewport composer; selected
 // pose/manual affine matrices still feed the geometry processor.
 source_motion_controller #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.MCU_CONFIG_DIGEST_ONLY(MCU_CONFIG_DIGEST_ONLY),.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT)) motion_control(.clk(clk),.rst_n(rst_n),.now_us(now_us),
  .runtime_motion_reset(runtime_motion_reset),.runtime_history_clear(runtime_history_clear),
  .submit_valid(SUPPORT_CONTROLS && motion_submit_valid),.submit_kind(motion_kind),.submit_entity(motion_entity),
  .submit_version(motion_version),.submit_id(motion_id),.submit_code(motion_submit_code),.read_kind(motion_read_kind),.read_status(motion_entity_status),
  .capture_admit(capture_valid && capture_ready),.capture_epoch(capture_epoch),.capture_frame(capture_id),.capture_exposure(capture_first),
  .capture_enable(SUPPORT_CONTROLS && affine_capture_enable),.capture_geometry(SUPPORT_CONTROLS?selected_capture_geometry:geometry_coefficients),
  .source_start(cap_start && cap_isp),.source_slot(src_slot),
  .mcu_enable(mcu_enable),.mcu_rx_valid(mcu_rx_valid),.mcu_rx_data(mcu_rx_data),.mcu_rx_error(mcu_rx_error),
  .mcu_tx_valid(mcu_tx_valid),.mcu_tx_ready(mcu_tx_ready),.mcu_tx_data(mcu_tx_data),
  .mcu_timing_valid(mcu_timing_valid),.mcu_capture_error(mcu_capture_error),.mcu_config_approved(mcu_config_approved),
  .mcu_new_session(mcu_new_session),.mcu_config_valid(mcu_config_valid),.mcu_config_entity(mcu_config_entity),
  .mcu_config_version(mcu_config_version),.mcu_config_crc32(mcu_config_crc32),.mcu_config_ready(mcu_config_ready),.mcu_reopen_required(mcu_reopen_required),
  .mcu_event_valid(mcu_event_valid),.mcu_event_payload(mcu_event_payload),.mcu_event_ready(mcu_event_ready),
  .mcu_session_valid(mcu_session_valid),.mcu_mapping_valid(mcu_mapping_valid),.mcu_boot_id(mcu_boot_id),
  .job_request(geo_valid),.job_slot(geo_src_slot),.job_epoch(processor_meta.epoch),.job_frame(processor_meta.frame_id),
  .job_original(source_geometry[geo_src_slot]),.job_accept(geo_valid && geo_ready),.prepared_valid(motion_prepared),.prepared_geometry(motion_geometry),
  .prepared_pose_status(motion_pose_state),.prepared_motion_status(motion_visual_state),.missed_results(motion_missed),
  .job_completion_config(completion_job_config),.job_registration_version(motion_registration_version),
  .job_motion_dx_q16(motion_job_dx),.job_motion_dy_q16(motion_job_dy),.job_motion_confidence(motion_job_confidence),
  .history_capture_enable(history_capture_enable),.history_clear(history_clear),.job_history_registration_ok(history_registration_ok),.job_entity_versions(motion_entity_versions));
 // Read-only kind 11 reports the actual final job, with the same authoritative
 // source identity. Capture-selected manual parameters are not dynamic output.
 reg [2303:0] motion_frame_status,motion_frame_pending;
 // Action state has its own applied identity in the read-only extension;
 // the completed job matrix/count/identity record remains frozen independently.
 wire [2303:0] motion_frame_read={motion_frame_status[2303:1280],runtime_action_status,motion_frame_status[959:0]};
 assign motion_status=motion_read_kind==11?motion_frame_read:motion_entity_status;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin motion_frame_status<=0;motion_frame_pending<=0;motion_frame_status[15:0]<=1;motion_frame_status[31:16]<=11;
   motion_frame_status[63:32]<=1;motion_frame_status[95:64]<=1;motion_frame_status[111:96]<=128;end
  else if(geo_valid && geo_ready)begin
   motion_frame_pending<=0;motion_frame_pending[15:0]<=1;motion_frame_pending[31:16]<=11;
   motion_frame_pending[63:32]<=1;motion_frame_pending[95:64]<=1;motion_frame_pending[111:96]<=128;
   motion_frame_pending[112]<=1;motion_frame_pending[128+:64]<=processor_meta.epoch;motion_frame_pending[192+:64]<=processor_meta.frame_id;
   motion_frame_pending[256+:192]<=motion_geometry[191:0];motion_frame_pending[448+:8]<={4'd0,motion_pose_state};
   motion_frame_pending[456+:8]<={4'd0,motion_visual_state};motion_frame_pending[480+:32]<=motion_missed;
   motion_frame_pending[736+:32]<=motion_registration_version;
   motion_frame_pending[768+:128]<=motion_entity_versions;motion_frame_pending[896+:32]<=processor_meta.geometry_version;motion_frame_pending[928+:32]<=processor_meta.isp_version;
   motion_frame_pending[464+:8]<=0;motion_frame_pending[512+:64]<=history_eligible?history_meta.epoch:64'd0;
   motion_frame_pending[576+:64]<=history_eligible?history_meta.frame_id:64'd0;
   motion_frame_pending[640+:96]<=0;
  end else if(geo_done)begin
   motion_frame_status<=motion_frame_pending;
   motion_frame_status[464+:8]<=!geo_failed && history_pixel_count!=0;
   motion_frame_status[640+:32]<=history_pixel_count;motion_frame_status[672+:32]<=invalid_pixel_count;
   motion_frame_status[704+:32]<=current_pixel_count;motion_frame_status[120+:8]<=geo_failed?8'd1:8'd0;
  end
 end
 end endgenerate
 wire mailbox_ready;
 assign geo_ready=mailbox_ready && tone_ready_ddr && motion_prepared;
 frame_meta_t processor_meta;wire [7:0] processor_enhancement;
 assign processor_meta=geo_metadata;assign processor_enhancement=processor_meta.enhancement_stage;
 geometry_processing_domain_external_refill #(.META_BITS(META_BITS),.EXTERNAL_TONE_PAGES(1),.HISTORY_SUPPORT(1)) processor(.clk(clk),.rst_n(rst_n),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),.job_valid(geo_valid && tone_ready_ddr && motion_prepared),.job_ready(mailbox_ready),
  .source_base(geo_src_base),.source_generation(geo_src_gen),.result_base(geo_dst_base),.result_generation(geo_dst_gen),
  .history_enable(history_eligible),.history_base(held_history_base),.history_generation(held_history_gen),
  .history_dx_q16(motion_job_dx),.history_dy_q16(motion_job_dy),.source_history(source_history),
  .current_pixels(current_pixel_count),.history_pixels(history_pixel_count),.invalid_pixels(invalid_pixel_count),
  .width(WIDTH[15:0]),.height(HEIGHT[15:0]),.coefficients(motion_geometry),.metadata(geo_metadata),.enhancement(SUPPORT_CONTROLS?processor_enhancement[1:0]:enhancement),.lut_version(source_tone_generation[geo_src_slot]),
  .lut_write(tone_loading),.lut_addr(tone_address),.lut_data(tone_value),.lut_commit(tone_commit),.lut_page(tone_write_page),.lut_program_version(tone_program_version),.job_done(geo_done),.job_failed(geo_failed),.result_metadata(),
  .source_req_valid(req_valid[2]),.source_req_ready(req_ready[2]),.source_req_addr(req_addr[64+:32]),.source_req_tag(req_tag[64+:32]),
  .source_req_beats(req_beats[10+:5]),.source_cancel(cancel[2]),.source_r_valid(r_valid[2]),.source_r_ready(r_ready[2]),
  .source_r_data(r_data[512+:256]),.source_r_last(r_last[2]),.source_done(done[2]),.source_done_ready(done_ready[2]),
  .source_error(error[2]),.source_cancelled(cancelled[2]),.source_done_tag(done_tag[64+:32]),
  .result_req_valid(req_valid[3]),.result_req_ready(req_ready[3]),.result_req_addr(req_addr[96+:32]),.result_req_tag(req_tag[96+:32]),
  .result_req_beats(req_beats[15+:5]),.result_cancel(cancel[3]),.result_w_valid(w_valid[3]),.result_w_ready(w_ready[3]),
  .result_w_data(w_data[768+:256]),.result_w_strb(w_strb[96+:32]),.result_done(done[3]),.result_done_ready(done_ready[3]),
  .result_error(error[3]),.result_cancelled(cancelled[3]),.result_done_tag(done_tag[96+:32]));

 // The network starts the byte reader on the exact frame handshake. Reader
 // drain is retained until MAC cancellation/last-packet drain also completes.
 reg network_active,reader_drained;reg [6:0] us_divider;reg [63:0] now_us;
 wire net_frame_ready,reader_ready,reader_done,reader_failed,net_cancel,net_release,net_failed;
 wire network_start=export_valid && !network_active && net_frame_ready && reader_ready;
 wire [31:0] network_complete_frames,network_failed_frames;
 wire network_byte_valid,network_byte_ready;wire [7:0] network_byte;
 assign export_ready=!network_active && net_frame_ready && reader_ready;
 assign export_release=net_release && reader_drained;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin network_active<=0;reader_drained<=0;us_divider<=0;now_us<=0;end
  else begin
   if(us_divider==124)begin us_divider<=0;now_us<=now_us+1'b1;end else us_divider<=us_divider+1'b1;
   if(network_start)begin network_active<=1;reader_drained<=0;end
   if(reader_done)reader_drained<=1;
   if(export_release && export_release_ready)network_active<=0;
  end
 end
 raw_network_service #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.CONFIGURED_PEER(!STATIC_ENDPOINTS)) network(.clk(clk),.rst_n(rst_n),.now_us(now_us),
  .gigabit_link_up(gigabit_link),.resolve(STATIC_ENDPOINTS && gigabit_link),.cancel(network_active && reader_failed),
  .local_mac(STATIC_ENDPOINTS?48'h020000000001:network_local_mac),.configured_peer_mac(network_peer_mac),
  .local_ip(STATIC_ENDPOINTS?32'hc0a85003:network_local_ip),.peer_ip(STATIC_ENDPOINTS?32'hc0a85002:network_peer_ip),
  .local_port(STATIC_ENDPOINTS?16'd50001:network_local_port),.peer_port(STATIC_ENDPOINTS?16'd50000:network_peer_port),
  .rx_data(rx_data),.rx_dv(rx_dv),.rx_er(rx_er),.tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),
  .frame_valid(export_valid && !network_active && reader_ready),.frame_ready(net_frame_ready),
  .epoch(export_meta.epoch),.frame_id(export_meta.frame_id),.param_version(export_meta.isp_version),.descriptor_id(32'h38574152),.bayer_code(8'd4),
  .byte_valid(network_byte_valid),.byte_ready(network_byte_ready),.byte_data(network_byte),
  .dma_cancel(net_cancel),
  .dma_drained(reader_drained),.release_valid(net_release),.release_ready(export_release_ready && reader_drained),.failed(net_failed),
  .peer_valid(),.resolution_failed(),.sent_packets(),.complete_frames(network_complete_frames),.failed_frames(network_failed_frames));
 // Frame-pool bases and 2048-byte RAW strides are always 32-byte aligned.
 raw_dma_reader #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.STRIDE(2048),.ALIGNED_ROWS(1)) reader(.clk(clk),.rst_n(rst_n),.start(network_start),.start_ready(reader_ready),
  .base_addr(export_base),.slot_begin(export_base),.slot_end(export_base+32'h00400000),.cancel(net_cancel),.done(reader_done),.failed(reader_failed),
  .req_valid(req_valid[5]),.req_ready(req_ready[5]),.req_addr(req_addr[160+:32]),.req_beats(req_beats[25+:5]),
  .r_valid(r_valid[5]),.r_ready(r_ready[5]),.r_data(r_data[1280+:256]),.dma_done(done[5]),.dma_done_ready(done_ready[5]),
  .dma_error(error[5] || cancelled[5] || done_tag[160+:32]!=export_gen),.dma_cancel(cancel[5]),
  .byte_valid(network_byte_valid),.byte_ready(network_byte_ready),.byte_data(network_byte));
 assign req_tag[160+:32]=export_gen;

 // Status layout is documented by the PC RGB control extension. Capability
 // bits advertise only connected functions; snapshot/MCU bits remain zero.
 assign control_status={
  network_failed_frames,network_complete_frames,capture_epoch,
  7'd0,last_statistics_failed,7'd0,last_statistics_valid,HEIGHT[15:0],last_statistics_saturated,
  WIDTH[15:0],last_statistics_dark,last_statistics_samples,last_statistics_sum,last_statistics_id,
  8'd1,8'd1,7'd0,mode_pending,6'd0,active_mode,active_mode_version,mode_applied_frame,mode_applied_epoch,
  failed_processing_frames,dropped_capture_frames,processed_frames,captured_frames,(SUPPORT_CONTROLS?32'h000000ff:32'h0000005f),32'h31424752};
 // Six clients retain RAW/S1 writes, geometry read/write, HDMI and RAW read.
 assign command=scheduler_command;
 assign req_bank={3'd2,3'd1,3'd1,3'd0,3'd0,3'd2};
 assign req_owner={3'd3,3'd2,3'd0,(source_history?3'd4:3'd1),3'd0,3'd0};
 // Scanout can still read the old held frame while a newer offer owns another
 // DISPLAY reference. Derive its slot from the immutable request address and
 // use the request's generation, never the mutable next-offer registers.
 wire [31:0] display_offset=display_req_addr-32'h01800000;
 assign req_slot={export_slot,display_offset[24:23],geo_dst_slot,(source_history?held_history_slot:geo_src_slot),src_slot,raw_slot};
 assign req_generation={export_gen,display_req_tag,geo_dst_gen,(source_history?held_history_gen:geo_src_gen),src_gen,raw_gen};
 assign req_valid[4]=display_req_valid,req_addr[128+:32]=display_req_addr,req_tag[128+:32]=display_req_tag,req_beats[20+:5]=display_req_beats;
 assign display_req_ready=req_ready[4],display_r_valid=r_valid[4],r_ready[4]=display_r_ready,display_r_data=r_data[1024+:256],display_r_last=r_last[4];
 assign display_done=done[4],done_ready[4]=display_done_ready,display_error=error[4],display_cancelled=cancelled[4],display_done_tag=done_tag[128+:32],cancel[4]=display_cancel;
 assign w_valid[2]=0,w_data[512+:256]=0,w_strb[64+:32]=0;
 assign w_valid[4]=0,w_data[1024+:256]=0,w_strb[128+:32]=0;
 assign w_valid[5]=0,w_data[1280+:256]=0,w_strb[160+:32]=0;
 assign r_ready[0]=1,r_ready[1]=1,r_ready[3]=1;
 // This board mapping has at most three simultaneous clients in SRC/DST,
 // two in RAW. Each client holds one request
 // until retirement/ACK. Size the scoreboards to those client bounds:
 // SRC/DST=3, RAW=2. Generic fabric capacity is unchanged.
 // Full tickets, frame generations, drain checks and three-frame pools remain.
 frame_memory_fabric #(.BANK_TXNS(4),.BOARD_CLIENT_LIMITS(1)) fabric(.clk(clk),.rst_n(rst_n),.controller_ready(controller_ready),.display_boundary(1'b1),
  .frame_command(command),.frame_response(response),.req_valid(req_valid),.req_ready(req_ready),.req_write(6'b001011),
  .req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),.req_bank(req_bank),.req_owner(req_owner),.req_slot(req_slot),.req_generation(req_generation),
  .urgent({1'b0,display_urgent,4'b0000}),.cancel(cancel),.w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_strb(w_strb),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.done(done),.done_ready(done_ready),.error(error),.cancelled(cancelled),.done_tag(done_tag),.fault(fault),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.awid(awid),.arid(arid),.awvalid(awvalid),.arvalid(arvalid),.awready(awready),.arready(arready),
  .native_wdata(native_wdata),.native_wstrb(native_wstrb),.native_wready(native_wready),.native_wlast(native_wlast),.native_wid(native_wid),
  .native_rdata(native_rdata),.native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rid(native_rid),.bus_bytes(),.max_wait_cycles(),.useful_write_bytes());
endmodule
