set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874/regional_route_20261020_012352_959075/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874/regional_route_20261020_012352_959075/candidate/dma.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874/regional_route_20261020_012352_959075/candidate/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874/regional_route_20261020_012352_959075/candidate/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874/regional_route_20261020_012352_959075/candidate/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
