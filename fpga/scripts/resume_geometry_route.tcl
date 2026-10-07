# Purpose: route a verified mapped/placed checkpoint with the same board
# constraints. PDS 2022.2-SP6.4 native pnr -help documents both DB inputs,
# action_timeout (minutes). The device rejects number_of_router_thread with
# Flow-0182, so retain its supported default router. No hardware access.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(GEOMETRY_RESUME_IMPL)
foreach path {
 constraints/mini_camera_diag/ddr_native.fdc constraints/ddr_board_pins.fdc
 constraints/mini_raw8_dual/geometry_pins.fdc constraints/mini_raw8_dual/timing.fdc
 constraints/mini_raw8_dual/cdc.fdc constraints/mini_raw8_dual/geometry_view_cdc.fdc
 constraints/mini_raw8_dual/geometry_priority.rcf
 constraints/placement.fdc
 constraints/mini_raw8_dual/geometry_reset_sites.fdc
} {add_constraint [file join $fpga_root $path]}
# The combined geometry RCF already contains every native DDR/HDMI priority.
# Adding the original RCF again would silently replace the combined file.
# Purpose: timing-driven reroute of the same placed cells. Performance mode
# and multi-corner hold repair change optimization effort, never constraints.
# Keep detailed reporting enabled so a failed run still identifies paths.
# Purpose: documented mapped-DB reuse avoids repeating unchanged synthesis.
# A fresh seed MUST omit input_place_db_file, or PDS retains the old placement.
# Keep the same mode/decongestion/constraints; record the selected seed in logs.
if {[info exists env(GEOMETRY_NEW_SEED)] && $env(GEOMETRY_NEW_SEED)>0} {
 # The mapped DB alone does not preserve the full physical pin/primitive
 # constraints. Import the same native device-map PCF before fresh placement.
 add_constraint $env(GEOMETRY_MAP_PCF)
 puts "GEOMETRY_FRESH_PLACEMENT_SEED $env(GEOMETRY_NEW_SEED) DECONGESTION $env(GEOMETRY_DECONGESTION)"
 pnr -input_db_file $env(GEOMETRY_MAP_DB) -force_to_run -action_timeout 180 -congest_overlap_limit 20 -gplace_seed $env(GEOMETRY_NEW_SEED) -plc_decongestion $env(GEOMETRY_DECONGESTION) -mode performance -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 10 -report_timing
} else {
 pnr -input_db_file $env(GEOMETRY_MAP_DB) -input_place_db_file $env(GEOMETRY_PLACE_DB) -force_to_run -action_timeout 180 -congest_overlap_limit 20 -gplace_seed 2 -mode performance -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 10 -report_timing
}
# Native shell may execute the queued PNR at script completion. STA belongs
# to a separate invocation, after the routed DB exists.
puts GEOMETRY_CHECKPOINT_PROJECT_CONFIGURED
