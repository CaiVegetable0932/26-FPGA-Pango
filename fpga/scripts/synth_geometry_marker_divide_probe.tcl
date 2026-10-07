# Purpose: isolated installed ADS synthesis of either the preserved original
# or candidate divider. No board PNR, project generation, constraints changes
# or bitstream. Commands match PDS 2022.2-SP6.4 ADS flow used by local probes.
set_dir -impl_directory $env(MARKER_DIVIDE_IMPL)
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design $env(MARKER_DIVIDE_SOURCE)
compile -top_module geometry_marker_divide
synthesize -ads -selected_syn_tool_opt 2
puts MARKER_DIVIDER_NATIVE_SYNTHESIS_COMPLETED
