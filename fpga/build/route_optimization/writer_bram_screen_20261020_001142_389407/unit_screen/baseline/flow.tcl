set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_bram_screen_20261020_001142_389407/unit_screen/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_bram_screen_20261020_001142_389407/unit_screen/baseline/writer.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_bram_screen_20261020_001142_389407/unit_screen/baseline/dma_pixel_pack.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_bram_screen_20261020_001142_389407/unit_screen/baseline/clock.fdc}
compile -top_module frame_pixel_writer -system_verilog
synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
