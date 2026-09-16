set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
pnr -input_db_file D:/XDU/concept/26-FPGA-Pango/fpga/build/pango_video_top/device_map/pango_video_top_map.adf -input_place_db_file D:/XDU/concept/26-FPGA-Pango/fpga/build/pango_video_top/place_route/pango_video_top_plc.adf -congest_overlap_limit 20 -action_timeout 15
