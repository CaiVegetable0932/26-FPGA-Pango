`timescale 1ns/1ps
`default_nettype none

// Purpose: PG2L100H native 1 Gb/s GMII-to-RGMII transmit-only adapter.
// Default: clk125_90 LAGS clk125 by 2 ns and external PHY TXID is disabled.
// PHY_TXID=1: the forwarding primitive uses clk125 itself; the board wrapper
// must verify PHY TXID is ENABLED. This avoids independent FPGA clock trees.
// GMII inputs meet clk125 rising-edge setup/hold; SAME_EDGE sends each sampled
// byte one full clk125 cycle later in the installed PDS 2022.2-SP6.4 model.
// reset_n asserts asynchronously and must be released safely for BOTH clocks
// after the board PLL locks. No PLL, reset synchronizer or PHY setup lives here.
// Before board sign-off, check RTL8211F TXID/straps/registers and external clock
// phase together: the 2 ns FPGA shift must not acquire a second PHY TX delay.
// Board wrappers may release the forwarded-clock reset in its own domain;
// default 0 preserves the original shared-reset subsystem integration contract.
module pango_rgmii_tx #(parameter SEPARATE_TXC_RESET=0,PHY_TXID=0)(
    input  wire       clk125,
    input  wire       clk125_90,
    input  wire       reset_n,
    input  wire       txc_reset_n,
    input  wire [7:0] gmii_data,
    input  wire       gmii_en,
    input  wire       gmii_error,
    output wire       rgmii_txc,
    output wire       rgmii_ctl,
    output wire [3:0] rgmii_data
);
    // Use the primitive's asynchronous reset, including its internal pipeline;
    // gating only D0/D1 would leave stale bytes at the pins after reset assertion.
    wire oddr_reset = ~reset_n;

    // Each pin transmits the sampled low bit on the rising edge and high bit
    // on the falling edge. Both halves use the SAME_EDGE capture and latency.
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1) begin : g_data
            GTP_ODDR_E1 #(
                .ODDR_MODE("SAME_EDGE"),
                .GRS_EN("TRUE"),
                .RS_TYPE("ASYNC_RESET")
            ) u_data_oddr (
                .Q(rgmii_data[bit_index]),
                .D0(gmii_data[bit_index]),
                .D1(gmii_data[bit_index + 4]),
                .CLK(clk125),
                .CE(1'b1),
                .RS(oddr_reset)
            );
        end
    endgenerate

    // RGMII encodes TX_EN on the rising edge and TX_EN XOR TX_ER on the
    // falling edge, including idle/error combinations where TX_EN is zero.
    GTP_ODDR_E1 #(
        .ODDR_MODE("SAME_EDGE"),
        .GRS_EN("TRUE"),
        .RS_TYPE("ASYNC_RESET")
    ) u_ctl_oddr (
        .Q(rgmii_ctl),
        .D0(gmii_en),
        .D1(gmii_en ^ gmii_error),
        .CLK(clk125),
        .CE(1'b1),
        .RS(oddr_reset)
    );

    // Forward the selected board clock through the same native output
    // primitive. Constants 1/0 give a centered sampling clock after reset
    // pipeline fill; there is deliberately no numeric IODELAY tap assumption.
    GTP_ODDR_E1 #(
        .ODDR_MODE("SAME_EDGE"),
        .GRS_EN("TRUE"),
        .RS_TYPE("ASYNC_RESET")
    ) u_txc_oddr (
        .Q(rgmii_txc),
        .D0(1'b1),
        .D1(1'b0),
        .CLK(PHY_TXID ? clk125 : clk125_90),
        .CE(1'b1),
        .RS(SEPARATE_TXC_RESET ? ~txc_reset_n : oddr_reset)
    );
endmodule

`default_nettype wire
