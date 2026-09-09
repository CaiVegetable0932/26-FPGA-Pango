# Native PDS batch entry for the first PG2L100H video-project integration.
# Keep all paths rooted at fpga/ so the script is independent of the caller's
# current directory. IP instances are added by their native .idf files.
set root [file normalize [file join [file dirname [info script]] ..]]

set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676

add_design [file join $root rtl pango_video_top.v]
add_design [file join $root rtl pango_ip_inventory.v]
add_design [file join $root ip pll_100h pll.idf]
add_design [file join $root ip line_fifo_100h fifo_test.idf]
add_design [file join $root ip line_ram_100h ram_test.idf]
# This DDR3 configuration is deliberately an IP candidate only. Its
# board-specific pads are not enabled until the physical MINI DDR is verified.
add_design [file join $root ip ddr3_100h ddr3_test.idf]
add_constraint [file join $root constraints pango_video_top.fdc]

compile -top_module pango_video_top
puts "PANGO_VIDEO_STAGE_PASS compile"
synthesize -ads -selected_syn_tool_opt 2
puts "PANGO_VIDEO_STAGE_PASS synthesize"
dev_map
puts "PANGO_VIDEO_STAGE_PASS dev_map"
pnr
puts "PANGO_VIDEO_STAGE_PASS pnr"
report_timing -delay_type min_max -max_path 100 -report_exception TRUE
puts "PANGO_VIDEO_STAGE_PASS report_timing"
gen_netlist -sdf_annotate FALSE
puts "PANGO_VIDEO_STAGE_PASS gen_netlist"
gen_bit_stream -scbv {High Voltage}
puts "PANGO_VIDEO_STAGE_PASS gen_bit_stream"
report_power
puts "PANGO_VIDEO_STAGE_PASS report_power"
puts "PANGO_VIDEO_BUILD_PASS"
