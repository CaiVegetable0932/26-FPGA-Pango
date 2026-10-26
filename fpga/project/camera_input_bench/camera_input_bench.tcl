# Purpose: isolated internal-path benchmark, no board pin/DDR/JTAG/bitstream flow.
set task_fpga [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $task_fpga build camera_input_20261012 pds implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $task_fpga rtl board reset_sync.v]
add_design [file join $task_fpga rtl input dvp_frame_receiver.v]
add_design [file join $task_fpga rtl input dvp_raw8_fanout.v]
add_design [file join $task_fpga rtl input dvp_clock_watchdog.v]
add_design [file join $task_fpga sim camera_input_bench.v]
add_constraint [file join $task_fpga project camera_input_bench internal_clock.fdc]
compile -top_module camera_input_bench
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 10 -report_exception TRUE
