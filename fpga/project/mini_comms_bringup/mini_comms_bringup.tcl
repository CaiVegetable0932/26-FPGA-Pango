# Purpose: native, isolated MINI communication commissioning project.
# No programming commands. Camera/HDMI baseline and its build tree are untouched.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build mini_comms_bringup implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl board reset_sync.v]
add_design [file join $fpga_root rtl board mini_comms_bringup.v]
add_design [file join $fpga_root ip comms_pll comms_pll.idf]
add_design [file join $fpga_root rtl control mcu_uart_rx.v]
add_design [file join $fpga_root rtl control mcu_uart_tx.v]
add_design [file join $fpga_root rtl control mcu_frame_rx.v]
add_design [file join $fpga_root rtl control mcu_frame_tx.v]
add_design [file join $fpga_root rtl control mcu_protocol.v]
add_design [file join $fpga_root rtl control comms_boot_config.v]
add_design [file join $fpga_root rtl network praw_packetizer.v]
add_design [file join $fpga_root rtl network udp_ipv4_eth_tx.v]
add_design [file join $fpga_root rtl network video_network_tx.v]
add_design [file join $fpga_root rtl network pango_rgmii_tx.v]
add_design [file join $fpga_root rtl network mdio_clause22.v]
add_design [file join $fpga_root rtl network rtl8211f_init.v]
add_design [file join $fpga_root rtl network comms_test_source.v]
add_constraint [file join $fpga_root constraints mini_comms_bringup pins.fdc]
add_constraint [file join $fpga_root constraints mini_comms_bringup timing.fdc]
compile -top_module mini_comms_bringup
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 10 -report_exception TRUE
gen_bit_stream -scbv {High Voltage}
