# Purpose: OFFLINE SBIT -> XT25F128 SPI-X1 SFC conversion only.
# PDS 2022.2-SP6.4 Fabric Configuration guide section 4.5.6. No scan, cable,
# server, erase, program, verify, reset or eFuse command is present.
cfg_set_tcl_break -flag true
cfg_gen_sfc -device_name xt25f128 -opcode 11 -sbit_start_address 0 -sbit $env(COMMS_SBIT) -sfc $env(COMMS_SFC)
puts COMMS_SFC_OFFLINE_GENERATED
cfg_close
