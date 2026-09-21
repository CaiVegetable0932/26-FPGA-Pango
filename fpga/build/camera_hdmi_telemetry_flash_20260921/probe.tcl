# Purpose: identify this board and Flash before replacing its configuration;
# read status without writing configuration, registers, keys or eFuses.
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_read_device_property -mode 3 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_disconnect
puts "CAMERA_VSYNC_PREFLIGHT_COMPLETE"
cfg_close
