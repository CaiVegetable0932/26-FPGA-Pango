set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/boot_local_capture_20261019_211117_597873/unit_screen_20261019_220554_646153/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/boot_local_capture_20261019_211117_597873/unit_screen_20261019_220554_646153/candidate/pc_video_boot.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/boot_local_capture_20261019_211117_597873/unit_screen_20261019_220554_646153/candidate/uart_8n1.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/boot_local_capture_20261019_211117_597873/unit_screen_20261019_220554_646153/candidate/uart_v2_parser.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/boot_local_capture_20261019_211117_597873/unit_screen_20261019_220554_646153/candidate/parameter_entity_guard.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/boot_local_capture_20261019_211117_597873/unit_screen_20261019_220554_646153/candidate/clock.fdc}
compile -top_module pc_video_boot -system_verilog
synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
