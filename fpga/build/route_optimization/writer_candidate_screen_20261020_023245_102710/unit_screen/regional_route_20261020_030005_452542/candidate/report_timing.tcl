set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/writer.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/dma_pixel_pack.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/scan_pins.fdc}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/device_map/regional_wrapper.pcf}
report_timing -force_to_run -input_db_file {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542/candidate/place_route/regional_wrapper_pnr.adf} -delay_type min_max -max_path 30 -report_exception TRUE
