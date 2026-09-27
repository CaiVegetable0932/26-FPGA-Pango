# Purpose: request the documented FPGA soft reset only, then read status.
# Source: PDS2022.2-SP6.4/doc/Fabric_Configuration_User_Guide.pdf p85.
# Caller must first verify the selected PG2L100H and completed Flash readback.
# This does not erase/program anything, alter boot/security bits, or claim that
# a cold boot occurred. UART capability evidence must establish the loaded image.
if {![info exists env(RAW8_FLASH_VERIFIED)] || $env(RAW8_FLASH_VERIFIED) ne "YES"} {
 error "Verified Flash image required before this diagnostic reset"
}
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_reset_fpga -device_index 0
# Purpose: full SPIx1 image load can exceed1.5s. Allow10s before status read;
# still require UART capabilities, never treat this delay as boot proof.
after 10000
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts "RAW8_SOFT_RESET_REQUEST_COMPLETED"
cfg_close
