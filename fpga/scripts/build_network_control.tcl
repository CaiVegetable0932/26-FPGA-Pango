# Standalone section07 internal timing/resource experiment for installed PDS
# 2022.2-SP6.4. It never rewrites board projects, constraints, IP or bitstreams.
# -work_dir must be a fresh directory in fpga/build/network_control_20261012.
# External IO delays are unverified; report only constrained internal paths.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set top network_timing_top
set group network
if {[info exists env(PANGO_07_CONTROL)] && $env(PANGO_07_CONTROL) == "1"} {
 set top control_timing_top
 set group control
}
set build_dir [file normalize [file join $fpga_root build network_control_20261012 pds_$group]]
if {[info exists env(PANGO_07_BUILD)]} {set build_dir [file normalize $env(PANGO_07_BUILD)]}
if {[string first [file normalize [file join $fpga_root build]] $build_dir] != 0} {
 error "Section07 build must stay in fpga/build"
}
set source_root [file join $build_dir source_snapshot]
if {![file isdirectory $source_root]} {set source_root $fpga_root}
set_dir -impl_directory $build_dir
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
foreach source [glob [file join $source_root rtl network *.sv]] {add_design $source}
foreach source [glob [file join $source_root rtl control *.sv]] {add_design $source}
add_design [file join $source_root sim ${top}.sv]
add_design [file join $source_root rtl memory dma_byte_unpack.v]
add_constraint [file join $source_root constraints network_control_internal.fdc]
compile -top_module $top
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 20 -report_exception TRUE
puts "NETWORK_CONTROL_INTERNAL_BUILD_FINISHED"
