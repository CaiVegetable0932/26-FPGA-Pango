# Purpose: perform a read-only JTAG scan of the PG2L100H and its external
# configuration Flash. This script assigns no file and issues no erase,
# program, security, key or eFuse operation.
cfg_set_tcl_break -flag true
puts "CONFIGURATION_TARGET=READ_ONLY_OUTER_FLASH_SCAN"

cfg_connect -ip 127.0.0.1 -port 65420
# Purpose: use the conservative 1 MHz TCK recommended for marginal or newly
# registered Flash devices before scanning the FPGA chain and outer Flash.
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_disconnect
puts "HDMI_OUTER_FLASH_SCAN_COMPLETED"
cfg_close
