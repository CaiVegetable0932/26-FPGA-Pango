# Purpose: inspect installed ADS RAM inference in an isolated development build.
# No project regeneration, board operation, or official-file output occurs.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_dir -impl_directory $env(CACHE_RAM_IMPL)
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root sim geometry_cache_ram_probe.v]
add_constraint [file join $fpga_root sim geometry_stream_clock.fdc]
compile -top_module geometry_cache_ram_probe
synthesize -ads -selected_syn_tool_opt 2
puts CACHE_RAM_NATIVE_SYNTHESIS_COMPLETED
