# Purpose: isolated PG2L100H synthesis/route benchmark using installed PDS flow.
# No board pins/IP/JTAG or bitstream generation; not a deployable board project.
set task_fpga [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $task_fpga build frame_manager pds implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $task_fpga rtl memory frame_manager_pkg.sv]
add_design [file join $task_fpga rtl memory frame_pool_bank.sv]
add_design [file join $task_fpga rtl memory frame_manager.sv]
add_design [file join $task_fpga sim frame_manager_bench.sv]
add_constraint [file join $task_fpga constraints frame_manager_bench.fdc]
compile -top_module frame_manager_bench -system_verilog -include_path [list [file join $task_fpga rtl memory]]
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 10 -report_exception TRUE
