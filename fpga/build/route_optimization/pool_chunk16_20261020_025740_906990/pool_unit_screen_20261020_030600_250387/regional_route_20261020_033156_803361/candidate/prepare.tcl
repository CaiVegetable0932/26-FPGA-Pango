set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361/candidate/frame_manager_pkg.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361/candidate/pool.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361/candidate/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361/candidate/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361/candidate/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
