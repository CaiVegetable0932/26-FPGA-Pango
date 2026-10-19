set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599/regional_route_20261020_035328_393663/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599/regional_route_20261020_035328_393663/baseline/frame_manager_pkg.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599/regional_route_20261020_035328_393663/baseline/pool.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599/regional_route_20261020_035328_393663/baseline/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599/regional_route_20261020_035328_393663/baseline/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599/regional_route_20261020_035328_393663/baseline/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
