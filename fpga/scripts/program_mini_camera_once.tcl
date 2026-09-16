# Purpose: one explicitly requested volatile SRAM diagnostic download; no Flash,
# eFuse, threshold/ADC writes, or long readback verification. The PowerShell
# launcher checks fresh identity/status and timing/hash evidence before this file.
cfg_set_tcl_break -flag true
set diagnostic_bitstream [file normalize $env(PANGO_MINI_DIAGNOSTIC_BITSTREAM)]
if {![file exists $diagnostic_bitstream]} {error "Missing diagnostic bitstream"}
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_assign_file -file $diagnostic_bitstream -device_index 0
cfg_set_device_property -device_index 0 -program 3
cfg_program -device_index 0
# Purpose: read status immediately after programming, before any video capture.
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts MINI_SRAM_DOWNLOAD_COMPLETED
cfg_close
