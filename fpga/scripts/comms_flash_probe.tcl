# Purpose: identify the current FPGA and external configuration Flash only.
# PDS 2022.2-SP6.4 Fabric Configuration manual sections 4.5.2 and 4.5.4.
# No erase, assignment, program, reset or eFuse commands.
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_read_device_property -mode 3 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_disconnect
puts "COMMS_FLASH_IDENTIFIED"
cfg_close
