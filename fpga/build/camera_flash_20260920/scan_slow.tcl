# Purpose: retry identification at the documented minimum TCK without erasing or programming Flash.
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 100Khz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_disconnect
cfg_close
