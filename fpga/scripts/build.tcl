# PDS 2022.2-SP6.4 User Guide p.248-255; complete explicit source import.
set root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $root rtl flow_smoke_top.v]
add_constraint [file join $root constraints flow_smoke.fdc]
add_simulation [file join $root sim tb_flow_smoke.v]
compile -top_module flow_smoke_top
puts "FLOW_STAGE_PASS compile"
synthesize -ads
puts "FLOW_STAGE_PASS synthesize"
dev_map
puts "FLOW_STAGE_PASS dev_map"
pnr
puts "FLOW_STAGE_PASS pnr"
# min_max is explicitly documented in Timing Analyzer User Guide p.15.
report_timing -delay_type min_max -max_path 100 -report_exception TRUE
puts "FLOW_STAGE_PASS report_timing"
gen_netlist -sdf_annotate FALSE
puts "FLOW_STAGE_PASS gen_netlist"
# Core board manual p.12: L4/L5 powered at 3.3 V; both unused by this design.
# PDS User Guide p.150 + official UG042003 V1.14 table 2-36: High Voltage.
# https://www.pangomicro.com/en/uploads/17503246_1729499157.pdf
gen_bit_stream -scbv {High Voltage}
puts "FLOW_STAGE_PASS gen_bit_stream"
# Tool estimate with default activity, never a measured power claim.
report_power
puts "FLOW_STAGE_PASS report_power"
puts "FLOW_BUILD_PASS"
