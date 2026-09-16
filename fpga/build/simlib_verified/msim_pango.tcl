# ----------------------------------------
# Create compilation libraries
vlib usim
vmap usim "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/usim"
vlib vsim
vmap vsim "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/vsim"
vlib adc_e2
vmap adc_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/adc_e2"
vlib ddc_e2
vmap ddc_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/ddc_e2"
vlib dll_e2
vmap dll_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/dll_e2"
vlib hsstlp_lane
vmap hsstlp_lane "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/hsstlp_lane"
vlib hsstlp_pll
vmap hsstlp_pll "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/hsstlp_pll"
vlib iolhr_dft
vmap iolhr_dft "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/iolhr_dft"
vlib ipal_e1
vmap ipal_e1 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/ipal_e1"
vlib ipal_e2
vmap ipal_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/ipal_e2"
vlib iserdes_e2
vmap iserdes_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/iserdes_e2"
vlib oserdes_e2
vmap oserdes_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/oserdes_e2"
vlib pciegen2
vmap pciegen2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/pciegen2"


#compile basic library
vlog -incr "E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation/*.v" -work usim
vlog -incr "E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation/modelsim10.2c/*.vp" -work usim


#compile basic library
vlog -incr "E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/bsim/*.v" -work vsim
vlog -incr "E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/bsim/modelsim10.2c/*.vp" -work vsim


#compile common library
cd "E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation/modelsim10.2c"
vmap adc_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/adc_e2"
vlog -incr -f ./filelist_adc_e2_gtp.f -work adc_e2
vmap ddc_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/ddc_e2"
vlog -incr -f ./filelist_ddc_e2_gtp.f -work ddc_e2
vmap dll_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/dll_e2"
vlog -incr -f ./filelist_dll_e2_gtp.f -work dll_e2
vmap hsstlp_lane "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/hsstlp_lane"
vlog -incr -f ./filelist_hsstlp_lane_gtp.f -work hsstlp_lane
vmap hsstlp_pll "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/hsstlp_pll"
vlog -incr -f ./filelist_hsstlp_pll_gtp.f -work hsstlp_pll
vmap iolhr_dft "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/iolhr_dft"
vlog -incr -f ./filelist_iolhr_dft_gtp.f -work iolhr_dft
vmap ipal_e1 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/ipal_e1"
vlog -incr -f ./filelist_ipal_e1_gtp.f -work ipal_e1
vmap ipal_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/ipal_e2"
vlog -incr -f ./filelist_ipal_e2_gtp.f -work ipal_e2
vmap iserdes_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/iserdes_e2"
vlog -incr -f ./filelist_iserdes_e2_gtp.f -work iserdes_e2
vmap oserdes_e2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/oserdes_e2"
vlog -incr -f ./filelist_oserdes_e2_gtp.f -work oserdes_e2
vmap pciegen2 "D:/XDU/concept/26-FPGA-Pango/fpga/build/simlib_verified/pciegen2"
vlog -incr -f ./filelist_pciegen2_gtp.f -work pciegen2 -sv -mfcu

quit -force

# ----------------------------------------
