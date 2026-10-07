# Purpose: export only the exact geometry routed DB after fresh passing STA.
# This helper does not connect JTAG, configure a board or modify Flash.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(GEOMETRY_IMPL)
gen_bit_stream -input_db_file $env(GEOMETRY_PNR_DB) -force_to_run -scbv {High Voltage}
puts GEOMETRY_EXACT_PNR_IMAGE_GENERATED
