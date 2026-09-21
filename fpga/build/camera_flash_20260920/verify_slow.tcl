# Purpose: verify existing Flash at reduced TCK without another erase/program cycle.
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 100Khz
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file $env(CAMERA_SFC) -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_disconnect
puts "CAMERA_FLASH_SLOW_VERIFY_COMPLETED"
cfg_close
