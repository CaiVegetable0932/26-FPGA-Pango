# Generated standalone MCU synthesis; no PNR or programming.
set_arch -family Logos2 -device PG2L100H -package FBG676 -speedgrade -6
add_design -verilog {C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango/fpga/rtl/control/mcu_uart_rx.v}
add_design -verilog {C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango/fpga/rtl/control/mcu_uart_tx.v}
add_design -verilog {C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango/fpga/rtl/control/mcu_frame_rx.v}
add_design -verilog {C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango/fpga/rtl/control/mcu_frame_tx.v}
add_design -verilog {C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango/fpga/rtl/control/mcu_protocol.v}
compile -top_module mcu_protocol -defined_parameters {CLK_HZ 125000000 BAUD 115200 RX_TIMEOUT_MS 20}
synthesize -ads -disable_io_insertion -frequency 125
puts {MCU_ADS_SYNTH_PASS}
