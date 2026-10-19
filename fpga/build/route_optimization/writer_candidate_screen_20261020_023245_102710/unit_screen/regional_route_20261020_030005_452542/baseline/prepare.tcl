set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/baseline/writer.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/baseline/dma_pixel_pack.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/baseline/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/baseline/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/baseline/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
