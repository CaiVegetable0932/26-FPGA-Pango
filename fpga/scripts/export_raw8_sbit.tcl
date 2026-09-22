# Purpose: generate ONLY a bitstream from the exact audited routed database.
# Installed gen_bit_stream -help documents -input_db_file and -force_to_run.
# No prerequisite rerun, JTAG connection, configuration change or programming.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(RAW8_IMPL)
gen_bit_stream -input_db_file $env(RAW8_PNR_DB) -force_to_run -scbv {High Voltage}
puts RAW8_EXACT_PNR_IMAGE_GENERATED
