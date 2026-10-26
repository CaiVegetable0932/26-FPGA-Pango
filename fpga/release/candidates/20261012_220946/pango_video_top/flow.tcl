set fpga_root {D:/XDU/concept/26-FPGA-Pango/fpga/build/bitstream_20261012/pango_video_top_20261012_220353_214298/source}
set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/bitstream_20261012/pango_video_top_20261012_220353_214298}
# Native tcl2prj input: flow commands must remain top-level for PDS 2022.2.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl board reset_sync.v]
# Shared native divider startup and per-domain reset recovery.
add_design [file join $fpga_root rtl board video_clock_start.v]
add_design [file join $fpga_root rtl board rgmii_phy_io.v]
add_design [file join $fpga_root rtl board tmds_serializer.v]
add_design [file join $fpga_root rtl memory ip_integration_bank.v]
add_design [file join $fpga_root rtl board pango_video_top.v]
add_design [file join $fpga_root ip sys_pll sys_pll.idf]
add_design [file join $fpga_root ip video_pll video_pll.idf]
add_design [file join $fpga_root ip ddr3_controller ddr3_controller.idf]
add_design [file join $fpga_root ip raw_async_fifo raw_async_fifo.idf]
add_design [file join $fpga_root ip net_tx_fifo net_tx_fifo.idf]
add_design [file join $fpga_root ip display_fifo display_fifo.idf]
add_design [file join $fpga_root ip ddr_write_fifo ddr_write_fifo.idf]
add_design [file join $fpga_root ip ddr_read_fifo ddr_read_fifo.idf]
add_design [file join $fpga_root ip isp_line_ram isp_line_ram.idf]
add_design [file join $fpga_root ip tile_cache_ram tile_cache_ram.idf]
add_design [file join $fpga_root ip parameter_ram parameter_ram.idf]
add_design [file join $fpga_root ip gamma_rom gamma_rom.idf]
add_design [file join $fpga_root ip geometry_mult geometry_mult.idf]
add_design [file join $fpga_root ip bilinear_multadd bilinear_multadd.idf]
add_design [file join $fpga_root ip statistics_mac statistics_mac.idf]
add_constraint [file join $fpga_root constraints ddr_native.fdc]
add_constraint [file join $fpga_root constraints ddr_board_pins.fdc]
add_constraint [file join $fpga_root constraints board_pins.fdc]
add_constraint [file join $fpga_root constraints clocks.fdc]
add_constraint [file join $fpga_root constraints placement.fdc]
# Single active RCF: native DDR priority nets plus local HDMI reset nets.
add_constraint [file join $fpga_root constraints routing.rcf]
compile -top_module pango_video_top
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 30 -report_exception TRUE
# Explicit offline candidate image generation.
gen_bit_stream -scbv {High Voltage}

