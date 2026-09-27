# Purpose: retry the exact assigned camera image after independent readback
# proves that its programmed prefix matches and its missing suffix is erased.
# This intentionally does not erase Flash or reset the FPGA; the caller must
# verify the prefix/suffix precondition before invoking this script.
# Source: PDS 2022.2-SP6.4 Fabric Configuration guide section 4.5.4.
if {![info exists env(CAMERA_FLASH_PROGRAM_ONLY_AUTHORIZED)] || $env(CAMERA_FLASH_PROGRAM_ONLY_AUTHORIZED) ne "YES"} {
    error "Explicit program-only authorization is required"
}
if {![info exists env(CAMERA_SFC)] || ![file exists $env(CAMERA_SFC)]} {
    error "Camera SFC file missing"
}
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
# Purpose: use a cable-supported conservative rate for this recovery write.
cfg_set_cable_property -index 0 -freq 500Khz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file $env(CAMERA_SFC) -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_disconnect
puts "CAMERA_FLASH_PROGRAM_ONLY_VERIFY_COMPLETED"
cfg_close
