set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/candidate/unpack.v}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/candidate/reader.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/candidate/clock.fdc}
compile -top_module raw_dma_reader -system_verilog
synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
