# Purpose: independent placement/routing candidate for the same verified map.
# Only the documented placement seed and execution budget differ; clocks,
# pins and timing exceptions remain the board's existing constraints.
# Diagnostic status: this direct-map attempt failed Place-0006 at the DDR
# command OSERDES. It is not the accepted checkpoint route or a release flow.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(GEOMETRY_ALT_IMPL)
foreach path {
 constraints/mini_camera_diag/ddr_native.fdc constraints/ddr_board_pins.fdc
 constraints/mini_raw8_dual/pins.fdc constraints/mini_raw8_dual/timing.fdc
 constraints/mini_raw8_dual/cdc.fdc constraints/placement.fdc
 constraints/mini_camera_diag/routing.rcf
} {add_constraint [file join $fpga_root $path]}
pnr -input_db_file $env(GEOMETRY_MAP_DB) -force_to_run -action_timeout 90 -congest_overlap_limit 20 -gplace_seed 3
puts GEOMETRY_SEED3_PROJECT_CONFIGURED
