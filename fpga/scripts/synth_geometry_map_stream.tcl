# Purpose: isolated native resource/timing estimate for the streaming mapper.
# This never overwrites the routed board candidate or emits a programming image.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_dir -impl_directory $env(MAP_STREAM_IMPL)
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
foreach name {geometry_mul_pipe geometry_map_stream} {
 add_design [file join $fpga_root rtl geometry ${name}.v]
}
add_constraint [file join $fpga_root sim geometry_stream_clock.fdc]
compile -top_module geometry_map_stream
synthesize -ads -selected_syn_tool_opt 2
puts MAP_STREAM_NATIVE_SYNTHESIS_COMPLETED

