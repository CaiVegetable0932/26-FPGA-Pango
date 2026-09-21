# Purpose: erase the entire user-authorized XT25F128 configuration Flash,
# program the selected camera image, and require native readback verification.
# Source: PDS 2022.2-SP6.4 Fabric Configuration guide sections 4.5.4/4.5.6.
# The caller must check PG2L100H/0x00602899 and XT25F128/0x0B4018 first.
# Whole-chip erasure destroys other Flash data; no eFuse/key operations occur.
if {![info exists env(CAMERA_FLASH_ERASE_AUTHORIZED)] || $env(CAMERA_FLASH_ERASE_AUTHORIZED) ne "YES"} {
    error "Explicit whole-chip erase authorization is required"
}
if {![info exists env(CAMERA_SFC)] || ![file exists $env(CAMERA_SFC)]} {
    error "Camera SFC file missing"
}
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file $env(CAMERA_SFC) -device_index 0
# Purpose: NOR programming cannot restore zero bits; erase before replacement.
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_disconnect
puts "CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED"
cfg_close
