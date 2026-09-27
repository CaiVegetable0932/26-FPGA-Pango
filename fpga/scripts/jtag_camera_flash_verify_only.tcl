# Purpose: independently re-check the already programmed camera Flash at a
# lower JTAG rate after a cable/readback error. No erase, program, reset,
# eFuse, key, or board configuration command is issued by this script.
# Source: PDS 2022.2-SP6.4 Fabric Configuration guide, sections 4.5.1/4.5.4.
if {![info exists env(CAMERA_SFC)] || ![file exists $env(CAMERA_SFC)]} {
    error "Candidate SFC file missing"
}
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
# Purpose: default to the previously successful 500 KHz readback and permit
# 100 KHz; this USB Cable II rejects the guide's general 300 KHz option.
set cable_freq 500Khz
if {[info exists env(CAMERA_JTAG_FREQ)]} {
    if {$env(CAMERA_JTAG_FREQ) ni {500Khz 100Khz}} {
        error "Unsupported read-only JTAG frequency"
    }
    set cable_freq $env(CAMERA_JTAG_FREQ)
}
cfg_set_cable_property -index 0 -freq $cable_freq
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
# Purpose: assign only the host comparison file; verification reads Flash.
cfg_jtag_flash_assign_file -file $env(CAMERA_SFC) -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_disconnect
puts "CAMERA_FLASH_READONLY_VERIFY_COMPLETED"
cfg_close
