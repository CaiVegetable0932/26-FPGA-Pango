# Purpose: PDS 2022.2-SP6.4 native project input for the isolated 100H diagnostic.
# Flow commands remain top-level for tcl2prj. Bitstream generation is separate
# from programming; JTAG/Flash/eFuse commands are never part of this project.
set fpga_root [file normalize [file join [file dirname [info script]] ../..]]
set_dir -impl_directory [file join $fpga_root build mini_camera_diag implementation]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root rtl board reset_sync.v]
# Shared transmitter derived from the board-validated chain; one lane implementation.
add_design [file join $fpga_root rtl hdmi hdmi_tx_rgb.v]
add_design [file join $fpga_root rtl hdmi hdmi_tx_oserdes.v]
add_design [file join $fpga_root rtl hdmi hdmi_tx_powerup_reset.v]
add_design [file join $fpga_root rtl hdmi tmds_encoder.v]
add_design [file join $fpga_root rtl hdmi sync_vg.v]
add_design [file join $fpga_root rtl hdmi hdmi_rgb565_expand.v]
add_design [file join $fpga_root rtl hdmi hdmi_test_pattern.v]
add_design [file join $fpga_root rtl hdmi hdmi_720p_diagnostic.v]
add_design [file join $fpga_root rtl mini_camera_diag mini_frame_pool.v]
add_design [file join $fpga_root rtl mini_camera_diag mini_dvp_observe.v]
# Purpose: one source-synchronous input bundle shared by observer and capture.
add_design [file join $fpga_root rtl mini_camera_diag mini_dvp_input.v]
# Purpose: post-config geometry measurements, coherent CDC, and diagnostic-only HDMI fallback.
add_design [file join $fpga_root rtl mini_camera_diag mini_dvp_measure.v]
add_design [file join $fpga_root rtl mini_camera_diag mini_diag_snapshot.v]
add_design [file join $fpga_root rtl mini_camera_diag mini_diag_raster.v]
# Purpose: verified sensor startup and SCCB readback replace the write-only wrapper.
add_design [file join $fpga_root rtl mini_camera_diag ov5640_sccb.v]
add_design [file join $fpga_root rtl mini_camera_diag ov5640_startup.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor Top.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera SCCB.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera data_init.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera camera.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor camera camera_data.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor cmos_write_req_gen.v]
# Replaced legacy sync_vg.v with shared rtl/hdmi implementation.
add_design [file join $fpga_root rtl mini_camera_diag vendor timing_gen_xy.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor video_rect_read_data.v]
# Replaced legacy hdmi tmds_encoder.v with shared rtl/hdmi implementation.
# Replaced legacy hdmi rgb2tmds.v with shared rtl/hdmi implementation.
# Replaced legacy hdmi outputserdes.v with shared rtl/hdmi implementation.
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 frame_read_write.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 frame_fifo_read.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 frame_fifo_write.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 mem_read_arbi.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 mem_write_arbi.v]
add_design [file join $fpga_root rtl mini_camera_diag vendor frame_ddr3 aq_axi_master_256.v]
add_design [file join $fpga_root ip ddr3_controller ddr3_controller.idf]
add_design [file join $fpga_root ip hdmi_tx_pll clk_hdmi.v]
add_design [file join $fpga_root ip mini_camera_diag afifo_16i_64o_512 afifo_16i_64o_512.idf]
add_design [file join $fpga_root ip mini_camera_diag afifo_64i_16o_128 afifo_64i_16o_128.idf]
add_constraint [file join $fpga_root constraints mini_camera_diag ddr_native.fdc]
add_constraint [file join $fpga_root constraints ddr_board_pins.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag board_pins.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag clocks.fdc]
add_constraint [file join $fpga_root constraints mini_camera_diag cdc.fdc]
add_constraint [file join $fpga_root constraints placement.fdc]
# Purpose: use the main board's local reset regions and the actual shared
# serializer net names; native IOL recovery/removal checks remain enabled.
add_constraint [file join $fpga_root constraints mini_camera_diag routing.rcf]
compile -top_module Top
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -congest_overlap_limit 20 -action_timeout 15
report_timing -delay_type min_max -max_path 10 -report_exception TRUE
# Purpose: create a volatile-configuration image only after the separately
# audited timing stage; the project contains no JTAG, Flash or eFuse command.
gen_bit_stream -scbv {High Voltage}
