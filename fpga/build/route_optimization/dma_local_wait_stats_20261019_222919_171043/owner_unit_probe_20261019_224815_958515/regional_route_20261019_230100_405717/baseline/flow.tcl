set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717/baseline/dma.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717/baseline/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717/baseline/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717/baseline/scan_pins.fdc}
compile -top_module regional_wrapper -system_verilog
synthesize -ads -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
dev_map
pnr -action_timeout 20 -gplace_seed 11 -plc_decongestion 1 -max_ctrl_chain_length 500 -mode normal -congest_overlap_limit 200 -dump_router_congestion_plot TRUE
report_timing -delay_type min_max -max_path 30 -report_exception TRUE
