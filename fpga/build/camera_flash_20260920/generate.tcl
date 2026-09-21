# Purpose: convert the audited camera diagnostic to XT25F128 SPI X1 boot image.
# PDS 2022.2-SP6.4 Fabric Configuration guide section 4.5.6; address zero only.
cfg_set_tcl_break -flag true
cfg_gen_sfc -device_name xt25f128 -opcode 11 -sbit_start_address 0 -sbit $env(CAMERA_SBIT) -sfc $env(CAMERA_SFC)
puts "CAMERA_SFC_GENERATED"
cfg_close
