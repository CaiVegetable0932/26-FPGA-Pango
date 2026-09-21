`timescale 1ns/1ps
// Purpose: hold the complete HDMI transmitter in reset after the video PLL
// locks, then release all pixel logic and OSERDES lanes on one pixel-clock
// edge. The saturating counter removes dependence on the external pushbutton
// and preserves the common reset release used by the board-vendor HDMI chain.
module hdmi_tx_powerup_reset #(
    parameter integer HOLD_BITS = 16
)(
    input  wire pixel_clk,
    input  wire pll_locked,
    output wire reset_n
);
    // FPGA configuration initializes this state even when a reset-held native
    // I/O divider has not produced a pixel edge yet. Otherwise cold-start RTL
    // simulation (and unspecified power-up state) can remain unknown forever.
    reg [HOLD_BITS-1:0] hold_count = {HOLD_BITS{1'b0}};

    // Purpose: assertion follows loss of PLL lock immediately; release occurs
    // only after 2^HOLD_BITS-1 stable pixel clocks and then remains saturated.
    always @(posedge pixel_clk or negedge pll_locked) begin
        if (!pll_locked)
            hold_count <= {HOLD_BITS{1'b0}};
        else if (!( &hold_count))
            hold_count <= hold_count + {{(HOLD_BITS-1){1'b0}}, 1'b1};
    end

    assign reset_n = &hold_count;
endmodule
