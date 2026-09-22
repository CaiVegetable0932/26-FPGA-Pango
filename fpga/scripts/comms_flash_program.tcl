# Purpose: whole-chip XT25F128 erase, communication image write and verification.
# Only after a fresh ID/Flash check, image audit and explicit user authorization.
# Caller keeps the native service/session logs in fpga/build, not vendor sources.
if {![info exists env(COMMS_FLASH_ERASE_AUTHORIZED)] || $env(COMMS_FLASH_ERASE_AUTHORIZED) ne "YES"} {
    error "Explicit whole-chip erase authorization required"
}
if {![info exists env(COMMS_SFC)] || ![file exists $env(COMMS_SFC)]} {
    error "Audited communication image required"
}
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file $env(COMMS_SFC) -device_index 0
# NOR zero-to-one replacement requires erasure; no unrelated eFuse/key operation.
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_disconnect
puts "COMMS_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED"
cfg_close
