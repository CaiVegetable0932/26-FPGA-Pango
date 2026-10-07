# Purpose: read the installed PG2L100H port constraint syntax for an isolated
# hold-timing diagnosis. No design/board is loaded and no constraint is applied.
# The shell work directory is a new fpga/build child, never the official tree.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
def_port -help
puts GEOMETRY_IO_TIMING_HELP_READ
