set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394/candidate/writer.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394/candidate/dma_pixel_pack.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394/candidate/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394/candidate/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394/candidate/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
