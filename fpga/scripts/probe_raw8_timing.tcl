# Purpose: diagnostic-only STA against an existing native routed DB. Any
# override is confined to a separate run; never use this probe as release proof.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory [pwd]
if {[info exists env(RAW8_PROBE_FDC)]} {add_constraint $env(RAW8_PROBE_FDC)}
report_timing -input_db_file $env(RAW8_PNR_DB) -force_to_run -delay_type min_max -max_path 10 -report_exception TRUE
puts RAW8_TIMING_PROBE_DONE
