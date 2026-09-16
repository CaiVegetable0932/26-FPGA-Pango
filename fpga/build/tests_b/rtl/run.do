onerror {quit -code 2 -force}
onbreak {quit -code 3 -force}
vlib work
vmap work work
vlog {D:/XDU/concept/26-FPGA-Pango/fpga/rtl/flow_smoke_top.v} {D:/XDU/concept/26-FPGA-Pango/fpga/sim/tb_flow_smoke.v}
vsim -t 1ps   work.tb_flow_smoke
run -all
quit -code 0 -force
