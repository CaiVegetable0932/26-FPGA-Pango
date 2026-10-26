# Purpose: PDS 2022.2-SP6.4 native project input for the isolated 100H diagnostic.
# Flow commands remain top-level for tcl2prj. Bitstream generation is separate
# from programming; JTAG/Flash/eFuse commands are never part of this project.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build mini_camera_diag implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl board reset_sync.v]
# Shared native divider startup and per-domain reset recovery.
add_design [file join $fpga_root rtl board video_clock_start.v]
add_design [file join $fpga_root rtl board tmds_serializer.v]
# Purpose: sensor identity/readback and pre-capture fixed exposure controller.
add_design [file join $fpga_root rtl mini_camera_diag ov5640_control.v]
add_design [file join $fpga_root rtl mini_camera_diag ov5640_timing_monitor.v]
add_design [file join $fpga_root rtl mini_camera_diag mini_frame_pool.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor Top.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera SCCB.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera data_init.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera camera.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera camera_data.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor cmos_write_req_gen.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor sync_vg.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor timing_gen_xy.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor video_rect_read_data.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor hdmi tmds_encoder.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor hdmi rgb2tmds.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor hdmi outputserdes.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 frame_read_write.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 frame_fifo_read.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 frame_fifo_write.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 mem_read_arbi.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 mem_write_arbi.v]
# Purpose: native FIFO adapter replaces generic AXI emulation (no fabricated B).
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 mini_ddr_native_bridge.v]
add_design [file join $fpga_root ip ddr3_controller ddr3_controller.idf]
add_design [file join $fpga_root ip video_pll video_pll.idf]
add_design [file join $fpga_root ip mini_camera_diag afifo_16i_64o_512 afifo_16i_64o_512.idf]
add_design [file join $fpga_root ip mini_camera_diag afifo_64i_16o_128 afifo_64i_16o_128.idf]
add_constraint [file join $fpga_root constraints mini_camera_diag ddr_native.fdc]
add_constraint [file join $fpga_root constraints ddr_board_pins.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag board_pins.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag clocks.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag cdc.fdc]
# Purpose: rely on PDS native OSERDES packing for local reset registers. The
# former guessed PAP_REGION coordinates were rejected by RouteConstraintEditor.
add_constraint [file join $fpga_root constraints mini_camera_diag routing.rcf]
compile -top_module Top
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 10 -report_exception TRUE
# Purpose: create a volatile-configuration image only after the separately
# audited timing stage; the project contains no JTAG, Flash or eFuse command.
gen_bit_stream -scbv {High Voltage}
