# Purpose: collect external configuration Flash contents for offline byte
# comparison after a failed verify. This does not erase/program/reset Flash,
# touch eFuse/keys, or alter the FPGA's current running configuration.
# Source: PDS 2022.2-SP6.4 Fabric Configuration guide section 4.5.4.
if {![info exists env(CAMERA_SFC)] || ![file exists $env(CAMERA_SFC)]} {
    error "Candidate SFC file missing"
}
if {![info exists env(CAMERA_READBACK)] || [file exists $env(CAMERA_READBACK)]} {
    error "Choose a fresh readback file"
}
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
# Purpose: this cable accepts 500 KHz for readback; its driver rejected the
# guide's general 300 KHz option during a read-only preflight.
cfg_set_cable_property -index 0 -freq 500Khz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file $env(CAMERA_SFC) -device_index 0
cfg_jtag_flash_readback -device_index 0 -file $env(CAMERA_READBACK)
cfg_disconnect
puts "CAMERA_FLASH_READBACK_ONLY_COMPLETED"
cfg_close
