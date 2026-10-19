`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: actual capture/ISP/frame-pool/geometry/RAW-network integration in
// the native 125 MHz DDR clock domain. Board wrappers supply atomic capture
// mailboxes and the pixel-domain display adapter. Processing throughput must
// be measured for this shared clock/bus; no 1080p30 timing claim is inferred.
module video_memory_core #(parameter WIDTH=1920,HEIGHT=1080,STATIC_ENDPOINTS=1,PROJECTIVE=1,SUPPORT_CONTROLS=0,SUPPORT_SNAPSHOT=0)(
 input clk,rst_n,controller_ready,input [447:0] geometry_coefficients,input [1:0] enhancement,
 input capture_valid,output capture_ready,output capture_complete,
 input mode_submit_valid,output mode_submit_ready,input [1:0] mode_submit,input [31:0] mode_version,
 input geometry_submit_valid,output geometry_submit_ready,input [543:0] geometry_submit,
 input [31:0] geometry_version,geometry_entity_id,output [767:0] geometry_status,
 output [767:0] control_status,snapshot_s1_status,snapshot_result_status,snapshot_geometry_status,input snapshot_arm,output snapshot_arm_ready,
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
 // Initial disabled mode is a real whole-entity seed. Later mode/version
 // commits occur only on a source capture boundary; old SRC descriptors retain
 // their own enhancement mode/version while newer captures change parameters.
 reg mode_seeded;wire mode_bank_ready,mode_pending,mode_applied;
 wire [1:0] active_mode,capture_mode;
 wire [31:0] active_mode_version,active_mode_entity,capture_mode_version,capture_mode_entity;
 wire [63:0] mode_applied_epoch,mode_applied_frame;
 wire mode_seed_request=SUPPORT_CONTROLS && !mode_seeded;
 wire mode_request_valid=mode_seed_request || (SUPPORT_CONTROLS && mode_submit_valid);
 assign mode_submit_ready=SUPPORT_CONTROLS && mode_seeded && mode_bank_ready;
 frame_parameter_bank #(.ENTITY_BITS(2)) modes(.clk(clk),.rst_n(rst_n),.submit_valid(mode_request_valid),.submit_ready(mode_bank_ready),
  .entity_validated(mode_seed_request || (mode_submit<3 && mode_version!=0)),.entity(mode_seed_request?2'd0:mode_submit),
  .version(mode_seed_request?32'd1:mode_version),.entity_id(mode_seed_request?32'd1:mode_version),.received(),.validated(),.rejected(),
  .capture_boundary(capture_valid && capture_ready),.epoch(capture_epoch),.frame_id(capture_id),
  .active_entity(active_mode),.active_version(active_mode_version),.active_entity_id(active_mode_entity),
  .capture_entity(capture_mode),.capture_version(capture_mode_version),.capture_entity_id(capture_mode_entity),
  .applied(mode_applied),.applied_ready(1'b1),.applied_epoch(mode_applied_epoch),.applied_frame(mode_applied_frame),.pending(mode_pending));
 always @(posedge clk or negedge rst_n)if(!rst_n)mode_seeded<=0;
  else if(mode_seed_request && mode_bank_ready)mode_seeded<=1;
 // A whole inverse projection/lens entity commits on the source boundary.
 // Each of the three SRC slots retains its own coefficients until PROCESS
 // retires. A later PC update cannot reinterpret an older queued source.
 reg geometry_seeded;wire geometry_bank_ready,geometry_pending;
 wire [543:0] active_geometry,capture_geometry;
 wire [31:0] active_geometry_version,active_geometry_id,capture_geometry_version,capture_geometry_id;
 wire [63:0] geometry_applied_epoch,geometry_applied_frame;
 wire geometry_seed_request=SUPPORT_CONTROLS && !geometry_seeded;
 assign geometry_submit_ready=SUPPORT_CONTROLS && geometry_seeded && geometry_bank_ready;
 frame_parameter_bank #(.ENTITY_BITS(544)) geometries(.clk(clk),.rst_n(rst_n),
  .submit_valid(geometry_seed_request || (SUPPORT_CONTROLS && geometry_submit_valid)),.submit_ready(geometry_bank_ready),
  .entity_validated(1'b1),.entity(geometry_seed_request?{32'h04000000,64'd0,geometry_coefficients}:geometry_submit),
  .version(geometry_seed_request?32'd1:geometry_version),.entity_id(geometry_seed_request?32'd1:geometry_entity_id),
  .received(),.validated(),.rejected(),.capture_boundary(capture_valid && capture_ready),.epoch(capture_epoch),.frame_id(capture_id),
  .active_entity(active_geometry),.active_version(active_geometry_version),.active_entity_id(active_geometry_id),
  .capture_entity(capture_geometry),.capture_version(capture_geometry_version),.capture_entity_id(capture_geometry_id),
  .applied(),.applied_ready(1'b1),.applied_epoch(geometry_applied_epoch),.applied_frame(geometry_applied_frame),.pending(geometry_pending));
 assign geometry_status={8'h47,16'd0,7'd0,geometry_pending,geometry_applied_frame,geometry_applied_epoch,
  active_geometry_version,active_geometry_id,active_geometry};
 reg [543:0] source_geometry[0:2];reg [543:0] admitted_geometry;integer geometry_slot;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin geometry_seeded<=0;admitted_geometry<=0;for(geometry_slot=0;geometry_slot<3;geometry_slot=geometry_slot+1)source_geometry[geometry_slot]<=0;end
  else begin
   if(geometry_seed_request && geometry_bank_ready)geometry_seeded<=1;
   if(capture_valid && capture_ready)admitted_geometry<=SUPPORT_CONTROLS?capture_geometry:{32'h04000000,64'd0,geometry_coefficients};
   if(cap_start && cap_isp)source_geometry[src_slot]<=admitted_geometry;
  end
 end
 wire [5*CMD_BITS-1:0] command,scheduler_command,snapshot_command;wire [5*RSP_BITS-1:0] response;
 wire [6:0] req_valid,req_ready,w_valid,w_ready,r_valid,r_ready,r_last,done,done_ready,error,cancelled,cancel;
 wire [223:0] req_addr,req_tag,req_generation,done_tag,w_strb;
 wire [34:0] req_beats;wire [20:0] req_bank,req_owner;wire [13:0] req_slot;
 wire [1791:0] w_data,r_data;
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
  capture_meta.isp_version=1;capture_meta.geometry_version=SUPPORT_CONTROLS?capture_geometry_version:1;capture_meta.enhancement_version=SUPPORT_CONTROLS?capture_mode_version:1;
  capture_meta.calibration_entity=SUPPORT_CONTROLS?capture_geometry_id:1;capture_meta.parameter_entity=SUPPORT_CONTROLS?capture_mode_entity:1;capture_meta.enhancement_stage=SUPPORT_CONTROLS?capture_mode:enhancement;
  capture_meta.mode=SUPPORT_CONTROLS?capture_mode:enhancement;capture_meta.pose_status=1; // No MCU sample is available in this cabling revision.
 end
 video_frame_scheduler #(.SUPPORT_SNAPSHOT(SUPPORT_SNAPSHOT)) scheduler(.clk(clk),.rst_n(rst_n),.fabric_ready(controller_ready && !fault),
  .response(response),.command(scheduler_command),
  .snapshot_arm(snapshot_arm),.snapshot_arm_ready(snapshot_arm_ready),.snapshot_ready(pair_ready),.snapshot_request(pair_request),
  .snapshot_source_slot(pair_ss),.snapshot_result_slot(pair_rs),.snapshot_source_gen(pair_sg),.snapshot_result_gen(pair_rg),.capture_valid(capture_valid),.capture_ready(capture_ready),.capture_metadata(capture_meta),
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
  .coefficients(IDENTITY_CCM),.in_tag({isp_y,isp_x}),.in_mask(isp_out_mask),
  .out_valid(ccm_valid),.out_ready(ccm_output_ready),.out_rgb(ccm_rgb),.out_mask(ccm_mask),.out_tag(ccm_coordinates));
 wire statistics_valid,statistics_failed;wire [63:0] statistics_id;wire [47:0] statistics_sum;
 wire [31:0] statistics_samples,statistics_dark,statistics_saturated;
 reg [63:0] last_statistics_id;reg [47:0] last_statistics_sum;
 reg [31:0] last_statistics_samples,last_statistics_dark,last_statistics_saturated;
 reg last_statistics_valid,last_statistics_failed;
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
  .frame_width(WIDTH[15:0]),.frame_height(HEIGHT[15:0]),.frame_bayer(2'd3),.black_levels(32'd0),
  .colour_gains(64'h1000100010001000),.frame_tag(capture_meta),.frame_abort(isp_abort_now),
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
 // Load all 256 entries into all twelve real LUT lanes before commit. Source
 // mode is frozen in the SRC descriptor, so mid-job control updates cannot
 // reinterpret this frame. This reference table remains immutable at runtime.
 reg [8:0] tone_cursor;reg tone_commit;
 wire [7:0] tone_value;wire tone_loading=SUPPORT_CONTROLS && !tone_cursor[8];
 legacy_tone_lut tone(.address(tone_cursor[7:0]),.value(tone_value));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin tone_cursor<=0;tone_commit<=0;end
  else begin tone_commit<=0;if(tone_loading)begin tone_cursor<=tone_cursor+1'b1;if(tone_cursor==255)tone_commit<=1;end end
 end
 frame_meta_t processor_meta;wire [7:0] processor_enhancement;
 assign processor_meta=geo_metadata;assign processor_enhancement=processor_meta.enhancement_stage;
 geometry_frame_processor #(.META_BITS(META_BITS),.PROJECTIVE(PROJECTIVE)) processor(.clk(clk),.rst_n(rst_n),.job_valid(geo_valid),.job_ready(geo_ready),
  .source_base(geo_src_base),.source_generation(geo_src_gen),.result_base(geo_dst_base),.result_generation(geo_dst_gen),
  .width(WIDTH[15:0]),.height(HEIGHT[15:0]),.coefficients(source_geometry[geo_src_slot][447:0]),.metadata(geo_metadata),.projective(source_geometry[geo_src_slot][543:448]),.enhancement(SUPPORT_CONTROLS?processor_enhancement[1:0]:enhancement),.lut_version(SUPPORT_CONTROLS?32'd1:32'd0),
  .lut_write(tone_loading),.lut_addr(tone_cursor[7:0]),.lut_data(tone_value),.lut_commit(tone_commit),.job_done(geo_done),.job_failed(geo_failed),.result_metadata(),
  .source_req_valid(req_valid[2]),.source_req_ready(req_ready[2]),.source_req_addr(req_addr[64+:32]),.source_req_tag(req_tag[64+:32]),
  .source_req_beats(req_beats[10+:5]),.source_cancel(cancel[2]),.source_r_valid(r_valid[2]),.source_r_ready(r_ready[2]),
  .source_r_data(r_data[512+:256]),.source_r_last(r_last[2]),.source_done(done[2]),.source_done_ready(done_ready[2]),
  .source_error(error[2]),.source_cancelled(cancelled[2]),.source_done_tag(done_tag[64+:32]),
  .result_req_valid(req_valid[3]),.result_req_ready(req_ready[3]),.result_req_addr(req_addr[96+:32]),.result_req_tag(req_tag[96+:32]),
  .result_req_beats(req_beats[15+:5]),.result_cancel(cancel[3]),.result_w_valid(w_valid[3]),.result_w_ready(w_ready[3]),
  .result_w_data(w_data[768+:256]),.result_w_strb(w_strb[96+:32]),.result_done(done[3]),.result_done_ready(done_ready[3]),
  .result_error(error[3]),.result_cancelled(cancelled[3]),.result_done_tag(done_tag[96+:32]),.cache_misses(),.cache_stalls(),.cache_bus_bytes());

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
 raw_network_service #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.CONFIGURED_PEER(!STATIC_ENDPOINTS),.SUPPORT_SNAPSHOT(SUPPORT_SNAPSHOT)) network(.clk(clk),.rst_n(rst_n),.now_us(now_us),
  .gigabit_link_up(gigabit_link),.resolve(STATIC_ENDPOINTS && gigabit_link),.cancel(network_active && reader_failed),
  .local_mac(STATIC_ENDPOINTS?48'h020000000001:network_local_mac),.configured_peer_mac(network_peer_mac),
  .local_ip(STATIC_ENDPOINTS?32'hc0a85003:network_local_ip),.peer_ip(STATIC_ENDPOINTS?32'hc0a85002:network_peer_ip),
  .local_port(STATIC_ENDPOINTS?16'd50001:network_local_port),.peer_port(STATIC_ENDPOINTS?16'd50000:network_peer_port),
  .rx_data(rx_data),.rx_dv(rx_dv),.rx_er(rx_er),.tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),
  .frame_valid(export_valid && !network_active && reader_ready),.frame_ready(net_frame_ready),
  .epoch(export_meta.epoch),.frame_id(export_meta.frame_id),.param_version(export_meta.isp_version),.descriptor_id(32'h38574152),.bayer_code(8'd4),
  .byte_valid(network_byte_valid),.byte_ready(network_byte_ready),.byte_data(network_byte),
  .snapshot_valid(snapshot_valid),.snapshot_ready(snapshot_ready),.snapshot_epoch(snapshot_meta.epoch),.snapshot_frame_id(snapshot_meta.frame_id),
  .snapshot_version(snapshot_type==2?snapshot_meta.isp_version:snapshot_meta.geometry_version),.snapshot_descriptor(snapshot_descriptor),.snapshot_type(snapshot_type),
  .snapshot_byte_valid(snapshot_byte_valid),.snapshot_byte_ready(snapshot_byte_ready),.snapshot_byte(snapshot_byte),
  .snapshot_cancel(snapshot_abort),.snapshot_dma_cancel(snapshot_cancel),.snapshot_drained(snapshot_drained),
  .snapshot_release(snapshot_release),.snapshot_release_ready(snapshot_release_ready),.snapshot_failed(),.dma_cancel(net_cancel),
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
  failed_processing_frames,dropped_capture_frames,processed_frames,captured_frames,((SUPPORT_CONTROLS?32'h000000ff:32'h0000005f) | (SUPPORT_SNAPSHOT?32'h00000100:32'd0)),32'h31424752};
 // Independent copy/export banks and source claims keep a slow PC from
 // retaining the main video pool. This service uses the existing boot peer.
 wire pair_request,pair_ready;wire [1:0] pair_ss,pair_rs;wire [31:0] pair_sg,pair_rg;
 wire snapshot_valid,snapshot_ready,snapshot_byte_valid,snapshot_byte_ready,snapshot_abort,snapshot_cancel,snapshot_drained,snapshot_release,snapshot_release_ready;
 wire [7:0] snapshot_byte,snapshot_type;wire [31:0] snapshot_descriptor;
 frame_meta_t snapshot_meta;
 wire client6_write;wire [2:0] client6_bank,client6_owner;wire [1:0] client6_slot;wire [31:0] client6_gen;
 generate if(SUPPORT_SNAPSHOT)begin: snapshot_connected
 video_snapshot_service #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) snapshots(.clk(clk),.rst_n(rst_n),.fabric_ready(controller_ready && !fault),
  .pair_request(pair_request),.pair_request_ready(pair_ready),.pair_ss(pair_ss),.pair_rs(pair_rs),.pair_sg(pair_sg),.pair_rg(pair_rg),.pair_geometry(source_geometry[pair_ss]),.response(response),.command(snapshot_command),
  .frame_valid(snapshot_valid),.frame_ready(snapshot_ready),.metadata(snapshot_meta),.image_type(snapshot_type),.descriptor(snapshot_descriptor),.s1_status(snapshot_s1_status),.result_status(snapshot_result_status),.geometry_status(snapshot_geometry_status),
  .byte_valid(snapshot_byte_valid),.byte_ready(snapshot_byte_ready),.byte_data(snapshot_byte),.net_cancel(snapshot_cancel),.net_release(snapshot_release),
  .net_drained(snapshot_drained),.net_release_ready(snapshot_release_ready),.net_abort(snapshot_abort),
  .req_valid(req_valid[6]),.req_ready(req_ready[6]),.req_write(client6_write),.req_addr(req_addr[192+:32]),.req_tag(req_tag[192+:32]),.req_beats(req_beats[30+:5]),
  .req_bank(client6_bank),.req_owner(client6_owner),.req_slot(client6_slot),.req_generation(client6_gen),
  .w_valid(w_valid[6]),.w_ready(w_ready[6]),.w_data(w_data[1536+:256]),.w_strb(w_strb[192+:32]),
  .r_valid(r_valid[6]),.r_ready(r_ready[6]),.r_data(r_data[1536+:256]),.dma_done(done[6]),.dma_done_ready(done_ready[6]),
  .dma_error(error[6]),.dma_cancelled(cancelled[6]),.done_tag(done_tag[192+:32]),.dma_cancel(cancel[6]));
 end else begin: snapshots_disabled
  assign snapshot_s1_status=0,snapshot_result_status=0,snapshot_geometry_status=0;
  assign snapshot_command=0,pair_ready=0,snapshot_valid=0,snapshot_byte_valid=0,snapshot_byte=0,snapshot_type=0,snapshot_descriptor=0,snapshot_meta='0,snapshot_abort=0,snapshot_drained=0,snapshot_release_ready=0;
  assign client6_write=0,client6_bank=3'd3,client6_owner=0,client6_slot=0,client6_gen=0;
  assign req_valid[6]=0,req_addr[192+:32]=0,req_tag[192+:32]=0,req_beats[30+:5]=0;
  assign w_valid[6]=0,w_data[1536+:256]=0,w_strb[192+:32]=0,r_ready[6]=1,done_ready[6]=1,cancel[6]=0;
 end endgenerate
 assign command=scheduler_command | snapshot_command;
 assign req_bank={client6_bank,3'd2,3'd1,3'd1,3'd0,3'd0,3'd2};
 assign req_owner={client6_owner,3'd3,3'd2,3'd0,3'd1,3'd0,3'd0};
 // Scanout can still read the old held frame while a newer offer owns another
 // DISPLAY reference. Derive its slot from the immutable request address and
 // use the request's generation, never the mutable next-offer registers.
 wire [31:0] display_offset=display_req_addr-32'h01800000;
 assign req_slot={client6_slot,export_slot,display_offset[24:23],geo_dst_slot,geo_src_slot,src_slot,raw_slot};
 assign req_generation={client6_gen,export_gen,display_req_tag,geo_dst_gen,geo_src_gen,src_gen,raw_gen};
 assign req_valid[4]=display_req_valid,req_addr[128+:32]=display_req_addr,req_tag[128+:32]=display_req_tag,req_beats[20+:5]=display_req_beats;
 assign display_req_ready=req_ready[4],display_r_valid=r_valid[4],r_ready[4]=display_r_ready,display_r_data=r_data[1024+:256],display_r_last=r_last[4];
 assign display_done=done[4],done_ready[4]=display_done_ready,display_error=error[4],display_cancelled=cancelled[4],display_done_tag=done_tag[128+:32],cancel[4]=display_cancel;
 assign w_valid[2]=0,w_data[512+:256]=0,w_strb[64+:32]=0;
 assign w_valid[4]=0,w_data[1024+:256]=0,w_strb[128+:32]=0;
 assign w_valid[5]=0,w_data[1280+:256]=0,w_strb[160+:32]=0;
 assign r_ready[0]=1,r_ready[1]=1,r_ready[3]=1;
 // This board mapping has at most three simultaneous clients in SRC/DST,
 // two in RAW and one in each snapshot bank. Each client holds one request
 // until retirement/ACK. Size the scoreboards to those client bounds:
 // SRC/DST=3, RAW=2, snapshots=1 each. Generic fabric capacity is unchanged.
 // Full tickets, frame generations, drain checks and three-frame pools remain.
 frame_memory_fabric #(.BANK_TXNS(4),.BOARD_CLIENT_LIMITS(1)) fabric(.clk(clk),.rst_n(rst_n),.controller_ready(controller_ready),.display_boundary(1'b1),.allow_snapshot(SUPPORT_SNAPSHOT!=0),
  .frame_command(command),.frame_response(response),.req_valid(req_valid),.req_ready(req_ready),.req_write({client6_write,6'b001011}),
  .req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),.req_bank(req_bank),.req_owner(req_owner),.req_slot(req_slot),.req_generation(req_generation),
  .urgent({2'b00,display_urgent,4'b0000}),.cancel(cancel),.w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_strb(w_strb),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.done(done),.done_ready(done_ready),.error(error),.cancelled(cancelled),.done_tag(done_tag),.fault(fault),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.awid(awid),.arid(arid),.awvalid(awvalid),.arvalid(arvalid),.awready(awready),.arready(arready),
  .native_wdata(native_wdata),.native_wstrb(native_wstrb),.native_wready(native_wready),.native_wlast(native_wlast),.native_wid(native_wid),
  .native_rdata(native_rdata),.native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rid(native_rid),.bus_bytes(),.max_wait_cycles(),.useful_write_bytes());
endmodule
