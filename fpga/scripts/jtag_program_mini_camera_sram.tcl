# Purpose: program only the volatile FPGA CRAM/SRAM with the already-audited
# MINI camera diagnostic image. No Flash, eFuse, key or persistent operation.
# The caller must verify a fresh pre-status and bind PANGO_VALIDATION_BITSTREAM.
set validation_bitstream [file normalize $env(PANGO_VALIDATION_BITSTREAM)]
if {![file exists $validation_bitstream]} { error "Validated bitstream is missing" }
cfg_set_tcl_break -flag true
puts "CONFIGURATION_TARGET=VOLATILE_FPGA_CRAM_ONLY"
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
# Purpose: record status immediately before configuration in the same session.
cfg_read_device_property -mode 3 -device_index 0
cfg_assign_file -file $validation_bitstream -device_index 0
cfg_set_device_property -device_index 0 -program 3 -readback 0
cfg_program -device_index 0
# Purpose: DONE/CRC/ID/over-temperature status is the immediate post-program gate.
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts "MINI_CAMERA_SRAM_PROGRAM_COMPLETED"
cfg_close
