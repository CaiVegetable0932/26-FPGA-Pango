# Purpose: isolated RAW8 configuration/SCCB native compile/synthesis, no programming.
set task_fpga [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $task_fpga build camera_input_20261012 control_pds]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $task_fpga rtl board reset_sync.v]
add_design [file join $task_fpga rtl mini_camera_diag vendor camera SCCB.v]
add_design [file join $task_fpga rtl input ov5640_register_service.v]
add_design [file join $task_fpga rtl input ov5640_raw8_mode.v]
add_design [file join $task_fpga sim camera_control_bench.v]
add_constraint [file join $task_fpga project camera_input_bench control_clock.fdc]
compile -top_module camera_control_bench
synthesize -ads -selected_syn_tool_opt 2
