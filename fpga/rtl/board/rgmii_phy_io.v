`timescale 1ns/1ps
// Native Logos2 DDR IO usage cross-checked against MINI 2_11_ethernet_test.
// This is the physical interface only, not a MAC. PHY delay/strap mode is
// deliberately not claimed validated; the integration top holds PHY in reset.
module rgmii_phy_io(
    input wire tx_clk, input wire reset,
    input wire [7:0] tx_data, input wire tx_valid,
    input wire rgmii_rxc, input wire [3:0] rgmii_rxd, input wire rgmii_rx_ctl,
    output wire rx_clk, output wire [7:0] rx_data, output wire rx_valid,
    output wire rx_error,
    output wire rgmii_txc, output wire [3:0] rgmii_txd, output wire rgmii_tx_ctl
);
    GTP_CLKBUFG rx_clock_buffer(.CLKIN(rgmii_rxc), .CLKOUT(rx_clk));
    wire [3:0] rising_data, falling_data;
    wire control_rising, control_falling;
    genvar i;
    generate for (i=0; i<4; i=i+1) begin: lane
        GTP_IDDR_E1 #(.GRS_EN("TRUE"), .IDDR_MODE("SAME_PIPELINED"), .RS_TYPE("SYNC_RESET"))
            rx_ddr(.Q0(rising_data[i]), .Q1(falling_data[i]), .CE(1'b1),
                   .CLK(rx_clk), .D(rgmii_rxd[i]), .RS(reset));
        GTP_ODDR_E1 #(.GRS_EN("TRUE"), .ODDR_MODE("SAME_EDGE"), .RS_TYPE("ASYNC_RESET"))
            tx_ddr(.Q(rgmii_txd[i]), .CE(1'b1), .CLK(tx_clk),
                   .D0(tx_data[i]), .D1(tx_data[i+4]), .RS(reset));
    end endgenerate
    GTP_IDDR_E1 #(.GRS_EN("TRUE"), .IDDR_MODE("SAME_PIPELINED"), .RS_TYPE("SYNC_RESET"))
        rx_control(.Q0(control_rising), .Q1(control_falling), .CE(1'b1),
                   .CLK(rx_clk), .D(rgmii_rx_ctl), .RS(reset));
    assign rx_data = {falling_data, rising_data};
    assign rx_valid = control_rising;
    assign rx_error = control_rising ^ control_falling;
    GTP_ODDR_E1 #(.GRS_EN("TRUE"), .ODDR_MODE("SAME_EDGE"), .RS_TYPE("ASYNC_RESET"))
        tx_control(.Q(rgmii_tx_ctl), .CE(1'b1), .CLK(tx_clk),
                   .D0(tx_valid), .D1(tx_valid), .RS(reset));
    GTP_ODDR_E1 #(.GRS_EN("TRUE"), .ODDR_MODE("SAME_EDGE"), .RS_TYPE("ASYNC_RESET"))
        tx_clock(.Q(rgmii_txc), .CE(1'b1), .CLK(tx_clk),
                 .D0(1'b1), .D1(1'b0), .RS(reset));
endmodule
