# Purpose: route a verified mapped/placed checkpoint with the same board
# constraints. PDS 2022.2-SP6.4 native pnr -help documents both DB inputs,
# action_timeout (minutes). The device rejects number_of_router_thread with
# Flow-0182, so retain its supported default router. No hardware access.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(GEOMETRY_RESUME_IMPL)
foreach path {
 constraints/mini_camera_diag/ddr_native.fdc constraints/ddr_board_pins.fdc
 constraints/mini_raw8_dual/pins.fdc constraints/mini_raw8_dual/timing.fdc
 constraints/mini_raw8_dual/cdc.fdc constraints/placement.fdc
 constraints/mini_camera_diag/routing.rcf
} {add_constraint [file join $fpga_root $path]}
# Purpose: timing-driven reroute of the same placed cells. Performance mode
# and multi-corner hold repair change optimization effort, never constraints.
# Keep detailed reporting enabled so a failed run still identifies paths.
pnr -input_db_file $env(GEOMETRY_MAP_DB) -input_place_db_file $env(GEOMETRY_PLACE_DB) -force_to_run -action_timeout 180 -congest_overlap_limit 20 -gplace_seed 2 -mode performance -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 10 -report_timing
# Native shell may execute the queued PNR at script completion. STA belongs
# to a separate invocation, after the routed DB exists.
puts GEOMETRY_CHECKPOINT_PROJECT_CONFIGURED
