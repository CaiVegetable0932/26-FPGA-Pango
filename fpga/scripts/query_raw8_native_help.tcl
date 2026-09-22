# Purpose: read installed PDS option documentation only; no implementation or I/O.
puts [info commands *run*]
puts [info commands *read*]
puts [info commands *load*]
puts [info commands *project*]
gen_netlist -help
report_timing -help
gen_bit_stream -help
generate_constraint -help
puts RAW8_NATIVE_HELP_DONE
