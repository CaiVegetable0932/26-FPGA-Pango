`timescale 1ns/1ps
// DDR-domain C3 pose / C6 fixed viewport coordinator after C4 withdrawal.
// Immutable source slots retain atomic configuration and bounded pose fallback.
// C5 storage/DDR ownership stays external; no unregistered history is eligible.
module source_motion_controller #(parameter WIDTH=1920,HEIGHT=1080,MCU_CONFIG_DIGEST_ONLY=0,SUPPORT_VIEWPORT=1)(
 input clk,rst_n,input [63:0] now_us,input runtime_motion_reset,runtime_history_clear,
 input submit_valid,input [15:0] submit_kind,input [1023:0] submit_entity,input [31:0] submit_version,submit_id,
 output [7:0] submit_code,input [15:0] read_kind,output [2303:0] read_status,
 input capture_admit,input [63:0] capture_epoch,capture_frame,capture_exposure,
 input capture_enable,input [447:0] capture_geometry,
 input source_start,input [1:0] source_slot,
 input mcu_enable,mcu_rx_valid,input [7:0] mcu_rx_data,input mcu_rx_error,
 output mcu_tx_valid,input mcu_tx_ready,output [7:0] mcu_tx_data,
 input mcu_timing_valid,input [31:0] mcu_capture_error,input mcu_config_approved,
 input [31:0] mcu_new_session,output mcu_config_valid,output [2111:0] mcu_config_entity,
 output [31:0] mcu_config_version,mcu_config_crc32,input mcu_config_ready,output mcu_reopen_required,
 output mcu_event_valid,output [319:0] mcu_event_payload,input mcu_event_ready,
 // Read-only identity/status exports let the board approve the exact MCU boot.
 output mcu_session_valid,mcu_mapping_valid,output [63:0] mcu_boot_id,
 input job_request,input [1:0] job_slot,input [63:0] job_epoch,job_frame,
 input [447:0] job_original,input job_accept,
 output reg prepared_valid,output reg [447:0] prepared_geometry,
 output reg [3:0] prepared_pose_status,prepared_motion_status,output reg [31:0] missed_results,
 output [127:0] job_completion_config,output [31:0] job_registration_version,
 output signed [31:0] job_motion_dx_q16,job_motion_dy_q16,output [15:0] job_motion_confidence,
 output history_capture_enable,history_clear,output job_history_registration_ok,output [127:0] job_entity_versions
);
 localparam [3:0] VISUAL_DISABLED=8;
 wire [255:0] cfg_s,cfg_v;wire [127:0] cfg_h;wire [1023:0] cfg_p;
 wire [31:0] ver_s,ver_v,ver_h,ver_p;
 wire [127:0] capture_versions;reg [127:0] admitted_versions;
 reg [127:0] source_versions[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 // Initialized is not ownership: frame_pool still exclusively owns reuse.
 reg [2:0] source_valid;
 motion_config_bank #(.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT)) config_bank(.clk(clk),.rst_n(rst_n),.submit_valid(submit_valid),.kind(submit_kind),.entity(submit_entity),
  .version(submit_version),.entity_id(submit_id),.submit_code(submit_code),.capture_boundary(capture_admit),.epoch(capture_epoch),.frame_id(capture_frame),
  .capture_stabilization(cfg_s),.capture_viewport(cfg_v),.capture_completion(cfg_h),.capture_pose(cfg_p),
  .stabilization(),.viewport(),.completion(),.pose(),.stabilization_version(ver_s),.viewport_version(ver_v),.completion_version(ver_h),.pose_version(ver_p),
  .capture_versions(capture_versions),.read_kind(read_kind),.status(read_status));
 reg [255:0] admitted_v;reg [127:0] admitted_h;
 reg [255:0] vcfg[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 reg [127:0] hcfg[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 reg [1023:0] admitted_p;reg [447:0] admitted_g;
 reg [1023:0] pcfg[0:2] /* synthesis syn_ramstyle="lut_ram" */;
 reg admitted_enable,source_enable[0:2];reg [63:0] admitted_epoch,admitted_frame,sepoch[0:2],sframe[0:2];
 reg [191:0] pose_matrix[0:2];reg pose_ready[0:2];
 reg [3:0] pose_status[0:2];
 reg last_enable;wire toggle=capture_admit && capture_enable!=last_enable;
 wire session_valid,mcstate,mapping_valid;wire [767:0] state_payload;wire [63:0] state_time,sync_time;
 wire signed [63:0] clock_offset;wire [31:0] clock_error;
 assign mcu_session_valid=session_valid,mcu_mapping_valid=mapping_valid;
 // Physical wiring/config/timestamp approval is explicit and defaults disabled
 // in the board wrapper until the independent MCU interface is commissioned.
 // Board integration can retain the validated CONFIG digest only; standalone
 // clients keep the complete entity by default for the existing byte API.
 mcu_readonly_client #(.CONFIG_DIGEST_ONLY(MCU_CONFIG_DIGEST_ONLY)) mcu(.clk(clk),.rst_n(rst_n),.now_us(now_us),.enable(mcu_enable),.new_session(mcu_new_session),
  .rx_valid(mcu_rx_valid),.rx_data(mcu_rx_data),.rx_error(mcu_rx_error),.timing_bound_valid(mcu_timing_valid),.capture_error_us(mcu_capture_error),
  .tx_valid(mcu_tx_valid),.tx_ready(mcu_tx_ready),.tx_data(mcu_tx_data),.session_valid(session_valid),.boot_id(mcu_boot_id),.session_id(),.reopen_required(mcu_reopen_required),
  .config_valid(mcu_config_valid),.config_ready(mcu_config_ready),.config_approved(mcu_config_approved),.config_entity(mcu_config_entity),.config_version(mcu_config_version),.config_crc32(mcu_config_crc32),
  .state_valid(mcstate),.state_payload(state_payload),.state_receive_us(state_time),.event_valid(mcu_event_valid),.event_ready(mcu_event_ready),.event_payload(mcu_event_payload),
  .mapping_valid(mapping_valid),.clock_offset_us(clock_offset),.clock_error_us(clock_error),.sync_received_us(sync_time),
  .bad_crc(),.bad_header(),.timeouts(),.overflows(),.rejected_states(),.rejected_replies(),.reconnects(),.event_drops());
 wire selected_valid,selected_ready,selector_ready;wire [63:0] selected_epoch,selected_frame;wire [767:0] selected_pose;
 wire [31:0] selected_error;wire [2:0] selected_status;
 pose_frame_selector selector(.clk(clk),.rst_n(rst_n),.clear(!session_valid),.state_valid(mcstate),.state_payload(state_payload),.receive_us(state_time),
  .mapping_valid(mapping_valid),.clock_offset_us(clock_offset),.clock_error_us(clock_error),.sync_received_us(sync_time),
  .frame_valid(capture_admit && mcu_enable),.frame_ready(selector_ready),.epoch(capture_epoch),.frame_id(capture_frame),.exposure_us(capture_exposure),
  .result_valid(selected_valid),.result_ready(selected_ready),.result_epoch(selected_epoch),.result_frame(selected_frame),.result_state(selected_pose),
  .result_receive_us(),.age_us(),.error_us(selected_error),.status(selected_status),.invalid_states(),.overwrites(),.degraded_frames());
 reg [1:0] selected_slot;reg selected_found;integer k;
 always @*begin selected_slot=0;selected_found=0;for(k=0;k<3;k=k+1)if(source_valid[k] && sepoch[k]==selected_epoch && sframe[k]==selected_frame)begin selected_slot=k;selected_found=1;end end
 wire pose_valid;wire [63:0] pose_epoch,pose_frame;wire [191:0] pose_result;wire [3:0] pose_result_status;
 // Every slot calibration came from config_bank's atomic legal-entity gate.
 // Sharing that proof removes duplicate layout-only sidecar fields; the model
 // still checks MCU version, pose freshness and per-sample angular bounds.
 pose_affine_model #(.CALIBRATION_PREVALIDATED(1)) pose_model(.clk(clk),.rst_n(rst_n),.clear(toggle),.request_valid(selected_valid && selected_found),.request_ready(selected_ready),
  .affine_enable(source_enable[selected_slot]),.calibration(pcfg[selected_slot]),.manual_matrix(pose_matrix[selected_slot]),
  .epoch(selected_epoch),.frame_id(selected_frame),.pose(selected_pose),.pose_status(selected_status),.time_error_us(selected_error),
  .result_valid(pose_valid),.result_ready(1'b1),.result_epoch(pose_epoch),.result_frame(pose_frame),.matrix(pose_result),.status(pose_result_status),.calibration_id());
 // C4 owns no sampler, matcher, trajectory or source-domain certificate.
 // Jobs only wait for their own C3 pose; a timeout uses the frozen manual M.
 reg composing;reg [15:0] wait_cycles;reg [31:0] chosen_zoom;
 wire own_result=job_slot<3 && source_valid[job_slot] && sepoch[job_slot]==job_epoch && sframe[job_slot]==job_frame;
 wire can_prepare=own_result && (pose_ready[job_slot] || wait_cycles==65535);
 wire compose_ready,compose_valid,compose_overflow;wire [191:0] composed;wire [63:0] composed_epoch,composed_frame;
 reg [447:0] held_original;
 // Fixed/manual crop uses the admitted zoom only. Legacy dynamic mode,
 // rejected by the bank, also has a deterministic fixed-minimum fallback.
 always @*begin
  chosen_zoom=65536;
  if(job_slot<3 && source_valid[job_slot] && source_enable[job_slot] && vcfg[job_slot][7:0]!=0)
   chosen_zoom=vcfg[job_slot][63:32];
 end
 wire compose_request=job_request && !prepared_valid && !composing && can_prepare;
 wire [191:0] selected_matrix=pose_ready[job_slot]?pose_matrix[job_slot]:job_original[191:0];
 generate if(SUPPORT_VIEWPORT)begin: viewport_enabled
  affine_dynamic_compose #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) composer(.clk(clk),.rst_n(rst_n),
   .request_valid(compose_request),.request_ready(compose_ready),.enabled(source_enable[job_slot]),
   .manual_matrix(selected_matrix),.zoom_q16(chosen_zoom),.epoch(job_epoch),.frame_id(job_frame),
   .result_valid(compose_valid),.result_ready(1'b1),.matrix(composed),.result_epoch(composed_epoch),.result_frame(composed_frame),.overflow(compose_overflow));
 end else begin: viewport_disabled
  // Only the separate crop is removed. Forward the same source-owned pose or
  // manual fallback, including when affine is disabled; never substitute an
  // identity matrix. Existing composing/prepared ownership still holds the
  // result until job_accept, and held_original retains every lens coefficient.
  reg direct_valid;reg [191:0] direct_matrix;reg [63:0] direct_epoch,direct_frame;
  assign compose_ready=!direct_valid,compose_valid=direct_valid,compose_overflow=1'b0;
  assign composed=direct_matrix,composed_epoch=direct_epoch,composed_frame=direct_frame;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin direct_valid<=0;direct_matrix<=0;direct_epoch<=0;direct_frame<=0;end
   else begin
    direct_valid<=0;
    if(compose_request && compose_ready)begin
     direct_valid<=1;direct_matrix<=selected_matrix;direct_epoch<=job_epoch;direct_frame<=job_frame;
    end
   end
  end
 end endgenerate
 // Public diagnostics retain deterministic cold-reset values. A stale RAM
 // row is not a source until source_start writes all fields and marks it valid.
 wire source_metadata_valid=job_slot<3 && source_valid[job_slot];
 assign job_completion_config=source_metadata_valid?hcfg[job_slot]:128'd0;
 assign job_registration_version=source_metadata_valid?source_versions[job_slot][31:0]:32'd0;
 assign job_entity_versions=source_metadata_valid?source_versions[job_slot]:128'd0;
 // Zero diagnostic offsets have ZERO confidence and are never a certificate.
 // Keep scheduler clear/release semantics and history storage interfaces intact.
 assign job_motion_dx_q16=0,job_motion_dy_q16=0,job_motion_confidence=0;
 assign history_capture_enable=capture_enable && cfg_h[0];
 assign history_clear=toggle || runtime_motion_reset || runtime_history_clear;
 assign job_history_registration_ok=1'b0;
 // Source start is the scheduler's allocation-to-capture edge; frame_pool
 // prevents reallocation while PROCESS/HISTORY owns the slot. Keep one write
 // port per immutable bank and no payload reset so ADS may infer LUTRAM.
 // Consumers require source_valid plus their exact epoch/frame before use.
 always @(posedge clk)begin
  if(rst_n && source_start && source_slot<3)begin
   vcfg[source_slot]<=admitted_v;hcfg[source_slot]<=admitted_h;
   pcfg[source_slot]<=admitted_p;source_versions[source_slot]<=admitted_versions;
  end
 end
 integer i;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   admitted_v<=0;admitted_h<=0;admitted_p<=0;admitted_g<=0;admitted_enable<=0;admitted_epoch<=0;admitted_frame<=0;admitted_versions<=0;
   last_enable<=0;prepared_valid<=0;prepared_geometry<=0;prepared_pose_status<=1;prepared_motion_status<=VISUAL_DISABLED;missed_results<=0;
   composing<=0;wait_cycles<=0;held_original<=0;source_valid<=0;
   for(i=0;i<3;i=i+1)begin source_enable[i]<=0;sepoch[i]<=0;sframe[i]<=0;
    pose_matrix[i]<=0;pose_ready[i]<=1;pose_status[i]<=1;
    end
  end else begin
   if(capture_admit)begin admitted_v<=cfg_v;admitted_h<=cfg_h;admitted_p<=cfg_p;admitted_g<=capture_geometry;admitted_versions<=capture_versions;
    admitted_enable<=capture_enable;admitted_epoch<=capture_epoch;admitted_frame<=capture_frame;last_enable<=capture_enable;end
   // Static slot writes avoid a wide variable-index merge network in ADS.
   // Each capture changes only its immutable source-owned register bank.
   for(i=0;i<3;i=i+1)if(source_start && source_slot==i)begin
    source_valid[i]<=1;
    source_enable[i]<=admitted_enable;sepoch[i]<=admitted_epoch;sframe[i]<=admitted_frame;
    pose_matrix[i]<=admitted_g[191:0];
    pose_ready[i]<=!admitted_enable || !admitted_p[0] || !mcu_enable;
    pose_status[i]<=mcu_enable?1:3;
   end
   for(i=0;i<3;i=i+1)begin
    // Allocation wins over a late result for the pre-edge occupant of this
    // slot. Epoch/frame update on the same edge must not admit that old pose.
    if(pose_valid && source_valid[i] && !(source_start && source_slot==i) && sepoch[i]==pose_epoch && sframe[i]==pose_frame)begin pose_matrix[i]<=pose_result;pose_status[i]<=pose_result_status;pose_ready[i]<=1;end
   end
   if(job_request && !prepared_valid && !composing && wait_cycles!=65535)wait_cycles<=wait_cycles+1;
   if(job_request && !prepared_valid && !composing && can_prepare && compose_ready)begin
    composing<=1;held_original<=job_original;prepared_pose_status<=pose_ready[job_slot]?pose_status[job_slot]:6;
    prepared_motion_status<=VISUAL_DISABLED;
    if(wait_cycles==65535)missed_results<=missed_results+1;
   end
   if(compose_valid)begin prepared_valid<=1;composing<=0;prepared_geometry<={held_original[447:192],composed};if(compose_overflow)prepared_motion_status<=5;end
   if(job_accept)begin prepared_valid<=0;wait_cycles<=0;end
  end
 end
endmodule
