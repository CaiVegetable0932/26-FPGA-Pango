# Purpose: PDS 2022.2-SP6.4 native project source for an internal communication
# subsystem. Large descriptor buses are internal integration ports, not package
# pins. This project deliberately stops at ADS synthesis: no placement/bitstream.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build fpga_comms implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl control mcu_uart_rx.v]
add_design [file join $fpga_root rtl control mcu_uart_tx.v]
add_design [file join $fpga_root rtl control mcu_frame_rx.v]
add_design [file join $fpga_root rtl control mcu_frame_tx.v]
add_design [file join $fpga_root rtl control mcu_protocol.v]
add_design [file join $fpga_root rtl network praw_packetizer.v]
add_design [file join $fpga_root rtl network udp_ipv4_eth_tx.v]
add_design [file join $fpga_root rtl network video_network_tx.v]
add_design [file join $fpga_root rtl network pango_rgmii_tx.v]
add_design [file join $fpga_root rtl control fpga_comms_top.v]
add_constraint [file join $fpga_root constraints fpga_comms_clocks.fdc]
compile -top_module fpga_comms_top
# ADS Synthesis User Guide PDF pages20/52: suppress pad insertion when compiling
# an internal hierarchy with wide descriptor/telemetry buses, not board ports.
synthesize -ads -disable_io_insertion -selected_syn_tool_opt 2
