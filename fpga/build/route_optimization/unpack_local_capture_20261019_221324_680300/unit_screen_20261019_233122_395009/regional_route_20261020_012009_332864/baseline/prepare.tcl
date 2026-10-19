set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864/baseline/unpack.v}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864/baseline/reader.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864/baseline/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864/baseline/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864/baseline/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
