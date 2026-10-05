# Purpose: inspect a project-owned snapshot of a placed/routed geometry DB
# using the same explicit board constraints as the native project. A
# placed-DB estimate is diagnostic
# only, not a replacement for fresh final min/max STA or bitstream gating.
# GEOMETRY_DIAG_DB and GEOMETRY_DIAG_IMPL must point inside fpga/build/.
# Official Timing Analyzer User Guide (PDS 2022.2-SP6.4), sections 1/2.1,
# documents PLC/PnR DB support. The first standalone PLC load did not retain
# the full FDC clock/delay set, so explicitly reload it; an unconstrained
# diagnostic must never be treated as timing success. This script does not
# relax constraints or access hardware.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(GEOMETRY_DIAG_IMPL)
foreach path {
 constraints/mini_camera_diag/ddr_native.fdc constraints/ddr_board_pins.fdc
 constraints/mini_raw8_dual/pins.fdc constraints/mini_raw8_dual/timing.fdc
 constraints/mini_raw8_dual/cdc.fdc constraints/placement.fdc
} {add_constraint [file join $fpga_root $path]}
# Purpose: allow a deeper read-only path inventory without rerouting or
# relaxing constraints. Limit the requested count to bound report growth.
set path_count 10
if {[info exists env(GEOMETRY_DIAG_PATHS)]} {
 set path_count $env(GEOMETRY_DIAG_PATHS)
 if {![string is integer -strict $path_count] || $path_count < 1 || $path_count > 1000} {
  error "GEOMETRY_DIAG_PATHS must be an integer in 1..1000"
 }
}
report_timing -input_db_file $env(GEOMETRY_DIAG_DB) -force_to_run -delay_type min_max -max_path $path_count -report_exception TRUE
puts GEOMETRY_DIAGNOSTIC_STA_COMPLETED
