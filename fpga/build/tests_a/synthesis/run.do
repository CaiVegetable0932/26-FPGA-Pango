onerror {quit -code 2 -force}
onbreak {quit -code 3 -force}
vlib work
vmap work work
vmap usim {D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2/usim}
vlog {D:/XDU/concept/26-FPGA-Pango/fpga/build/flow_20260907_a/synthesize/flow_smoke_top_syn.vm} {D:/XDU/concept/26-FPGA-Pango/fpga/sim/tb_flow_smoke.v}
vsim -t 1ps -L usim  work.tb_flow_smoke
run -all
quit -code 0 -force
