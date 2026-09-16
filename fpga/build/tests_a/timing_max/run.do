onerror {quit -code 2 -force}
onbreak {quit -code 3 -force}
vlib work
vmap work work
vmap vsim {D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2/vsim}
vlog {D:/XDU/concept/26-FPGA-Pango/fpga/build/flow_20260907_a/generate_netlist/flow_smoke_top_sim.v} {D:/XDU/concept/26-FPGA-Pango/fpga/sim/tb_flow_smoke.v}
vsim -t 1ps -L vsim -sdfmax /tb_flow_smoke/dut={D:/XDU/concept/26-FPGA-Pango/fpga/build/flow_20260907_a/generate_netlist/flow_smoke_top_sta.sdf} work.tb_flow_smoke
run -all
quit -code 0 -force
