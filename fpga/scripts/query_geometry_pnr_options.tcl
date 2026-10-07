# Purpose: read the installed native PNR option definitions without running
# placement/routing or touching hardware. Logs stay in the supplied audit dir.
set_dir -impl_directory $env(GEOMETRY_PNR_HELP_DIR)
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
pnr -help
puts GEOMETRY_PNR_OPTIONS_READ
