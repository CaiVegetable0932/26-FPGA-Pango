# Native tcl2prj input. PDS needs flow commands at the top level to identify
# the synthesis tool before parsing design files; do not hide them in source.
# Keep this GUI project recipe aligned with scripts/build_video.tcl.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build pango_video_top]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl pango_video_top.v]
add_design [file join $fpga_root rtl pango_ip_inventory.v]
add_design [file join $fpga_root ip pll_100h pll.idf]
add_design [file join $fpga_root ip line_fifo_100h fifo_test.idf]
add_design [file join $fpga_root ip line_ram_100h ram_test.idf]
# Candidate only: not instantiated until physical MINI DDR parameters match.
add_design [file join $fpga_root ip ddr3_100h ddr3_test.idf]
add_constraint [file join $fpga_root constraints pango_video_top.fdc]
compile -top_module pango_video_top
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr
report_timing -delay_type min_max -max_path 100 -report_exception TRUE
gen_netlist -sdf_annotate FALSE
gen_bit_stream -scbv {High Voltage}
report_power
