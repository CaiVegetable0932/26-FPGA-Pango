# Purpose: native PDS compilation/synthesis of the new RAW8 network endpoint.
# This is an OFFLINE COMPONENT project, not the assembled MINI board top.
# No pins, download or bitstream command: a component pass cannot authorize burn.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build raw8_network_core implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl raw8_dual raw8_network_output.v]
add_design [file join $fpga_root rtl raw8_dual raw8_unpack.v]
add_design [file join $fpga_root rtl network praw_packetizer.v]
add_design [file join $fpga_root rtl network udp_ipv4_eth_tx.v]
add_design [file join $fpga_root rtl network video_network_tx.v]
add_constraint [file join $fpga_root constraints raw8_network_core.fdc]
compile -top_module raw8_network_output
synthesize -ads -selected_syn_tool_opt 2
