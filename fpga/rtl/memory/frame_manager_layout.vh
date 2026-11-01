// Purpose: generated internal packed offsets; regenerate with
// fpga/scripts/generate_frame_manager_layout.py. Source: frame_manager_pkg.sv.
// These offsets are not a UART/UDP encoding.
`ifndef FRAME_MANAGER_LAYOUT_VH
`define FRAME_MANAGER_LAYOUT_VH
`define FM_META_BITS 616
`define FM_META_EPOCH 552 +: 64
`define FM_META_FRAME_ID 488 +: 64
`define FM_META_CAPTURE_FIRST 424 +: 64
`define FM_META_CAPTURE_LAST 360 +: 64
`define FM_META_ISP_VERSION 328 +: 32
`define FM_META_GEOMETRY_VERSION 296 +: 32
`define FM_META_ENHANCEMENT_VERSION 264 +: 32
`define FM_META_CALIBRATION_ENTITY 232 +: 32
`define FM_META_PARAMETER_ENTITY 200 +: 32
`define FM_META_POSE_ENTITY 168 +: 32
`define FM_META_MODE 136 +: 32
`define FM_META_STRIDE 104 +: 32
`define FM_META_ERRORS 72 +: 32
`define FM_META_WIDTH 56 +: 16
`define FM_META_HEIGHT 40 +: 16
`define FM_META_FORMAT 24 +: 16
`define FM_META_STAGE 16 +: 8
`define FM_META_ENHANCEMENT_STAGE 8 +: 8
`define FM_META_POSE_STATUS 0 +: 8
`define FM_CMD_BITS 1043
`define FM_CMD_ALLOC 1042 +: 1
`define FM_CMD_META 426 +: 616
`define FM_CMD_CONSUMERS 422 +: 4
`define FM_CMD_SEAL 421 +: 1
`define FM_CMD_SEAL_SLOT 419 +: 2
`define FM_CMD_SEAL_GEN 387 +: 32
`define FM_CMD_LEGAL 386 +: 1
`define FM_CMD_CAPTURE_LAST 322 +: 64
`define FM_CMD_FRAME_ERRORS 290 +: 32
`define FM_CMD_CANCEL 289 +: 1
`define FM_CMD_CANCEL_SLOT 287 +: 2
`define FM_CMD_CANCEL_GEN 255 +: 32
`define FM_CMD_ACQUIRE 251 +: 4
`define FM_CMD_RELEASE_MASK 247 +: 4
`define FM_CMD_SKIP_MASK 243 +: 4
`define FM_CMD_RELEASE_SLOTS 235 +: 8
`define FM_CMD_RELEASE_GENS 107 +: 128
`define FM_CMD_ISSUE 106 +: 1
`define FM_CMD_ISSUE_SLOT 104 +: 2
`define FM_CMD_ISSUE_GEN 72 +: 32
`define FM_CMD_ISSUE_OWNER 69 +: 3
`define FM_CMD_COMPLETE 68 +: 1
`define FM_CMD_COMPLETE_TOKEN 65 +: 3
`define FM_CMD_COMPLETE_TICKET 1 +: 64
`define FM_CMD_COMPLETE_ERROR 0 +: 1
`define FM_RSP_BITS 2889
`define FM_RSP_ALLOC_READY 2888 +: 1
`define FM_RSP_ALLOC_SLOT 2886 +: 2
`define FM_RSP_ALLOC_GEN 2854 +: 32
`define FM_RSP_ALLOC_BASE 2822 +: 32
`define FM_RSP_SEAL_OK 2821 +: 1
`define FM_RSP_CANCEL_OK 2820 +: 1
`define FM_RSP_ACQUIRE_OK 2816 +: 4
`define FM_RSP_RELEASE_OK 2812 +: 4
`define FM_RSP_SKIP_OK 2808 +: 4
`define FM_RSP_ACQUIRE_SLOTS 2800 +: 8
`define FM_RSP_ACQUIRE_GENS 2672 +: 128
`define FM_RSP_ACQUIRE_META 208 +: 2464
`define FM_RSP_ISSUE_READY 207 +: 1
`define FM_RSP_ISSUE_REJECTED 206 +: 1
`define FM_RSP_ISSUE_TOKEN 203 +: 3
`define FM_RSP_ISSUE_TICKET 139 +: 64
`define FM_RSP_COMPLETE_OK 138 +: 1
`define FM_RSP_REJECTED 137 +: 1
`define FM_RSP_OCCUPIED 134 +: 3
`define FM_RSP_READY_FRAMES 131 +: 3
`define FM_RSP_PUBLISHED 99 +: 32
`define FM_RSP_INVALID_FRAMES 67 +: 32
`define FM_RSP_REJECTED_CYCLES 35 +: 32
`define FM_RSP_SKIPPED 3 +: 32
`define FM_RSP_PEAK_SLOTS 0 +: 3
`endif
