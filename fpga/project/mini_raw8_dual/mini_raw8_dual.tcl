# Purpose: PDS 2022.2-SP6.4 native full MINI camera/DDR/HDMI/GE project.
# No synthetic source, programming commands, or dependencies on reference/.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build mini_raw8_dual implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl board mini_raw8_dual.v]
add_design [file join $fpga_root rtl board reset_sync.v]
foreach src [glob [file join $fpga_root rtl raw8_dual *.v]] {add_design $src}
foreach src [glob [file join $fpga_root rtl control *.v]] {add_design $src}
foreach name {praw_packetizer udp_ipv4_eth_tx video_network_tx pango_rgmii_tx mdio_clause22 rtl8211f_init} {
 add_design [file join $fpga_root rtl network ${name}.v]
}
foreach name {hdmi_tx_rgb hdmi_tx_oserdes hdmi_tx_powerup_reset tmds_encoder} {
 add_design [file join $fpga_root rtl hdmi ${name}.v]
}
add_design [file join $fpga_root rtl mini_camera_diag mini_dvp_input.v]
add_design [file join $fpga_root rtl mini_camera_diag ov5640_sccb.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera data_init.v]
add_design [file join $fpga_root ip ddr3_controller ddr3_controller.idf]
add_design [file join $fpga_root ip hdmi_tx_pll clk_hdmi.v]
add_design [file join $fpga_root ip comms_pll comms_pll.v]
add_design [file join $fpga_root ip raw8_word_cdc raw8_word_cdc.idf]
add_design [file join $fpga_root ip raw8_capture_cdc raw8_capture_cdc.idf]
add_constraint [file join $fpga_root constraints mini_camera_diag ddr_native.fdc]
add_constraint [file join $fpga_root constraints ddr_board_pins.fdc]
add_constraint [file join $fpga_root constraints mini_raw8_dual pins.fdc]
add_constraint [file join $fpga_root constraints mini_raw8_dual timing.fdc]
add_constraint [file join $fpga_root constraints mini_raw8_dual cdc.fdc]
add_constraint [file join $fpga_root constraints placement.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag routing.rcf]
compile -top_module mini_raw8_dual
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 10 -report_exception TRUE
gen_bit_stream -scbv {High Voltage}
