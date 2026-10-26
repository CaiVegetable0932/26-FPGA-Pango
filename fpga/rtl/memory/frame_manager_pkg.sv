// Purpose: internal frame-control types, independent of UART/UDP wire encoding.
// Epoch/frame_id are authoritative u64 source identities; entity handles must
// refer to immutable, readable parameter records retained by the integration.
package frame_manager_pkg;
 localparam integer SRC=0, DST=1, RAW=2;
 localparam integer PROCESS=0, DISPLAY=1, NETWORK=2, HISTORY=3; // Internal one-frame history; never a network export.
 typedef struct packed {
  logic [63:0] epoch, frame_id, capture_first, capture_last;
  logic [31:0] isp_version, geometry_version, enhancement_version;
  logic [31:0] calibration_entity, parameter_entity, pose_entity;
  logic [31:0] mode, stride, errors;
  logic [15:0] width, height, format;
  logic [7:0] stage, enhancement_stage, pose_status;
 } frame_meta_t;
 localparam integer META_BITS=$bits(frame_meta_t);
 // Purpose: independent operation lanes. Requests execute on a clock edge only
 // when the matching response accepts them. Full allocation/issue queues stall;
 // bad tagged operations are rejected and counted, never mutate another frame.
 typedef struct packed {
  logic alloc;
  frame_meta_t meta;
  logic [3:0] consumers;
  logic seal;
  logic [1:0] seal_slot;
  logic [31:0] seal_gen;
  logic legal;
  logic [63:0] capture_last;
  logic [31:0] frame_errors;
  logic cancel;
  logic [1:0] cancel_slot;
  logic [31:0] cancel_gen;
  logic [3:0] acquire;
  logic [3:0] release_mask, skip_mask;
  logic [7:0] release_slots;
  logic [127:0] release_gens;
  logic issue;
  logic [1:0] issue_slot;
  logic [31:0] issue_gen;
  logic [2:0] issue_owner; // 0=producer writes; 1..4=consumer reads.
  logic complete;
  logic [2:0] complete_token;
  // Long-running burst traffic must not exhaust a 32-bit ticket in hours.
  logic [63:0] complete_ticket;
  logic complete_error;
 } frame_cmd_t;
 typedef struct packed {
  logic alloc_ready;
  logic [1:0] alloc_slot;
  logic [31:0] alloc_gen, alloc_base;
  logic seal_ok, cancel_ok;
  logic [3:0] acquire_ok, release_ok, skip_ok;
  logic [7:0] acquire_slots;
  logic [127:0] acquire_gens;
  logic [4*META_BITS-1:0] acquire_meta;
  logic issue_ready, issue_rejected; // Distinct from errors in other command lanes.
  logic [2:0] issue_token;
  logic [63:0] issue_ticket;
  logic complete_ok, rejected;
  logic [2:0] occupied, ready_frames;
  logic [31:0] published, invalid_frames, rejected_cycles, skipped;
  logic [2:0] peak_slots;
 } frame_rsp_t;
 localparam integer CMD_BITS=$bits(frame_cmd_t), RSP_BITS=$bits(frame_rsp_t);
endpackage
