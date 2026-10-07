# Purpose: inspect installed constraint-import options only. No build/hardware.
set_dir -impl_directory $env(GEOMETRY_PNR_HELP_DIR)
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_constraint -help
puts GEOMETRY_CONSTRAINT_OPTIONS_READ
