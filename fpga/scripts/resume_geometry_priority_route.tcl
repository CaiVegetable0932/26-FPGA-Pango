# Purpose: priority-only native configure/PNR/STA/SBIT stages. The wrapper
# supplies project-owned frozen inputs and validates each actual native .pds.
# PDS 2022.2-SP6.4 User Guide 5.3/5.4/9.1 (physical pp166/167/248)
# documents -file/-work_dir/-project_name and add_constraint. PNR options
# follow the existing installed-release runner; no vendor files are edited.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set run_dir [file normalize $env(GEOMETRY_PRIORITY_RUN)]
set frozen_rcf [file normalize [file join $run_dir routing geometry_priority.rcf]]
if {![file isfile $frozen_rcf]} {error "Missing frozen priority RCF"}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $run_dir
# Purpose: keep the entire original FDC budget and native PCF unchanged.
# There is exactly ONE RCF; the original is replaced, never added alongside.
foreach path {
 constraints/mini_camera_diag/ddr_native.fdc constraints/ddr_board_pins.fdc
 constraints/mini_raw8_dual/geometry_pins.fdc constraints/mini_raw8_dual/timing.fdc
 constraints/mini_raw8_dual/cdc.fdc constraints/mini_raw8_dual/geometry_view_cdc.fdc
 constraints/placement.fdc constraints/mini_raw8_dual/geometry_reset_sites.fdc
} {add_constraint [file join $fpga_root $path]}
add_constraint $frozen_rcf
add_constraint $env(GEOMETRY_MAP_PCF)
set stage $env(GEOMETRY_PRIORITY_STAGE)
switch -- $stage {
 configure {
  # Configuration-only invocation materializes the ACTUAL native project
  # for pre-PNR inspection. Never manufacture a .pds evidence file in Tcl.
 }
 pnr {
  # Seed zero reuses the exact checkpoint PLC; a positive seed omits it.
  # Both retain performance mode, decongestion and multi-corner hold repair.
  if {$env(GEOMETRY_NEW_SEED) == 0} {
   pnr -input_db_file $env(GEOMETRY_MAP_DB) -input_place_db_file $env(GEOMETRY_PLACE_DB) -force_to_run -action_timeout 180 -congest_overlap_limit 20 -gplace_seed 2 -plc_decongestion $env(GEOMETRY_DECONGESTION) -mode performance -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 10 -report_timing
  } else {
   pnr -input_db_file $env(GEOMETRY_MAP_DB) -force_to_run -action_timeout 180 -congest_overlap_limit 20 -gplace_seed $env(GEOMETRY_NEW_SEED) -plc_decongestion $env(GEOMETRY_DECONGESTION) -mode performance -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 10 -report_timing
  }
 }
 sta {
  # Separate process consumes the preserved PNR snapshot with identical FDC
  # and frozen RCF. An intermediate placement estimate cannot satisfy STA.
  report_timing -input_db_file $env(GEOMETRY_PNR_DB) -force_to_run -delay_type min_max -max_path 10 -report_exception TRUE
 }
 sbit {
  # Wrapper admits this stage only after fresh min/max STA and provenance.
  gen_bit_stream -input_db_file $env(GEOMETRY_PNR_DB) -force_to_run -scbv {High Voltage}
 }
 default {error "Unapproved priority-only stage"}
}
# PDS may parse a script twice: evidence is written by PowerShell only after
# process exit, not here. Native work may be queued until script completion.
puts "GEOMETRY_PRIORITY_STAGE_CONFIGURED $stage"
