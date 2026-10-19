`timescale 1ns/1ps
import frame_manager_pkg::*;
// Purpose: five independent banks preserve the authoritative 76 MiB byte layout.
// S0/S1/results receive the same upstream source identity, never a local counter.
// Each bank accepts allocation/seal/acquire/release/transactions independently.
// Reset is a fabric-wide cold reset: the adapter must flush responses before
// reset release. fabric_ready is a startup gate, not a substitute for draining.
module frame_manager #(parameter TXNS=8, parameter BOARD_CLIENT_LIMITS=0)(
 input wire clk, reset_n, fabric_ready, display_boundary,
 input wire [5*CMD_BITS-1:0] command,
 output wire [5*RSP_BITS-1:0] response
);
 import frame_manager_pkg::*;
 // Purpose: flattened bank ports reduce tool-dependent array-of-struct port
 // handling. Each slice remains an atomic typed command/response.
 genvar bank;
 generate for(bank=0;bank<5;bank=bank+1) begin : banks
  localparam [31:0] BANK_BASE=(bank==SRC)?32'h00000000:
   (bank==DST)?32'h01800000:(bank==RAW)?32'h03000000:
   (bank==SNAP_S1)?32'h03c00000:32'h04400000;
  frame_cmd_t bank_command;
  frame_rsp_t bank_response;
  assign bank_command=command[bank*CMD_BITS+:CMD_BITS];
  assign response[bank*RSP_BITS+:RSP_BITS]=bank_response;
  // The board admits at most one request per connected client.
  // Only the board mode specializes transaction capacity; triple frame pools,
  // full 64-bit tickets and completion/drain ownership stay unchanged.
  localparam BANK_TOKENS=BOARD_CLIENT_LIMITS ? (bank==SRC || bank==DST ? 3 : bank==RAW ? 2 : 1) : TXNS;
  frame_pool_bank #(.SLOTS(bank>=SNAP_S1?1:3),.BASE(BANK_BASE),.TXNS(BANK_TOKENS),
   .SLOT_BYTES(bank==RAW?32'h00400000:32'h00800000),.STRIDE(bank==RAW?2048:6144))
   pool(clk,reset_n,fabric_ready,display_boundary,bank_command,bank_response);
 end endgenerate
endmodule
