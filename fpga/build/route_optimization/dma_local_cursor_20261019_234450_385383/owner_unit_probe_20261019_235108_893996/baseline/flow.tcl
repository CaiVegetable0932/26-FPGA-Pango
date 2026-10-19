set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_cursor_20261019_234450_385383/owner_unit_probe_20261019_235108_893996/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_cursor_20261019_234450_385383/owner_unit_probe_20261019_235108_893996/baseline/dma.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/dma_local_cursor_20261019_234450_385383/owner_unit_probe_20261019_235108_893996/baseline/clock.fdc}
compile -top_module ddr_native_dma -system_verilog
synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
