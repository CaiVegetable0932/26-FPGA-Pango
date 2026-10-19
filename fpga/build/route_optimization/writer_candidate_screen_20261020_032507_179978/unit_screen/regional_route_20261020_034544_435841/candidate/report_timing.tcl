set_dir -impl_directory {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/writer.sv}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/dma_pixel_pack.v}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/clock.fdc}
add_design {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/regional_wrapper.sv}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/scan_pins.fdc}
add_constraint {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/device_map/regional_wrapper.pcf}
report_timing -force_to_run -input_db_file {D:/XDU/concept/26-FPGA-Pango/fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841/candidate/place_route/regional_wrapper_pnr.adf} -delay_type min_max -max_path 30 -report_exception TRUE
