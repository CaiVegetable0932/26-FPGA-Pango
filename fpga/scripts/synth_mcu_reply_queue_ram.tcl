# Purpose: standalone resource-inference audit of an UNINTEGRATED queue.
# This does not use or overwrite the board's active implementation directory.
# No placement, routing, bitstream generation or hardware access is performed.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
set_dir -impl_directory $env(QUEUE_RAM_AUDIT_IMPL)
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design [file join $fpga_root sim candidates mcu_reply_queue_ram.v]
compile -top_module mcu_reply_queue_ram
synthesize -ads -selected_syn_tool_opt 2
puts QUEUE_RAM_NATIVE_SYNTHESIS_COMPLETED
