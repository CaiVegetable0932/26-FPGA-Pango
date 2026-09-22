# Purpose: export native post-route netlist/constraints for clock-path diagnosis.
# Read only the selected existing PNR database; outputs remain in this run dir.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory [pwd]
gen_netlist -input_db_file $env(RAW8_PNR_DB) -force_to_run -sdf_annotate TRUE -process_corner slow
puts RAW8_NATIVE_MAPPING_EXPORTED
