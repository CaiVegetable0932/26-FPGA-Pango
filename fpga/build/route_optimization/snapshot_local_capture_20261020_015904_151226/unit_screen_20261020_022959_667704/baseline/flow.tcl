set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/snapshot_local_capture_20261020_015904_151226/unit_screen_20261020_022959_667704/baseline}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/snapshot_local_capture_20261020_015904_151226/unit_screen_20261020_022959_667704/baseline/snapshot_copy_dma.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/snapshot_local_capture_20261020_015904_151226/unit_screen_20261020_022959_667704/baseline/clock.fdc}
compile -top_module snapshot_copy_dma -system_verilog
synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2
