`timescale 1ns/1ps
// Purpose: serialize one 10-bit TMDS symbol with the native Logos2 master/slave
// DDR10TO1 topology and drive one differential HDMI lane. Port connectivity is
// intentionally kept equivalent to the MINI 2_10 HDMI reference implementation;
// unused primitive ports remain open instead of being routed through fabric.
module hdmi_tx_oserdes(
    input  wire       pixel_clk,
    input  wire       serial_clk,
    input  wire       reset_n,
    input  wire [9:0] symbol,
    output wire       data_p,
    output wire       data_n
);
    wire serial_data;
    wire cascade0;
    wire cascade1;

    // Purpose: use main's established per-lane release on the native divided
    // pixel clock. The I/O divider, not two separate global clock trees, defines
    // the serial/parallel phase. Each register drives only its master/slave pair.
    (* syn_preserve = 1, syn_maxfan = 2 *) reg lane_reset;
    always @(posedge pixel_clk or negedge reset_n)
        if (!reset_n) lane_reset <= 1'b1;
        else lane_reset <= 1'b0;

    // Purpose: use the vendor TMDS-capable differential output primitive. The
    // final bank voltage and drive mode are selected by the board constraints.
    GTP_OUTBUFDS #(
        .IOSTANDARD("TMDS")
    ) u_output_buffer (
        .O  (data_p),
        .OB (data_n),
        .I  (serial_data)
    );

    // Purpose: retain the native reference ASYNC_RESET master/slave topology;
    // reset recovery/removal is checked against the real shared I/O clock tree.
    GTP_OSERDES_E2 #(
        .GRS_EN("TRUE"), .OSERDES_MODE("DDR10TO1"),
        .TSERDES_EN("FALSE"), .UPD0_SHIFT_EN("FALSE"),
        .UPD1_SHIFT_EN("FALSE"), .INIT_SET(2'b00),
        .GRS_TYPE_DQ("RESET"), .LRS_TYPE_DQ0("ASYNC_RESET"),
        .LRS_TYPE_DQ1("ASYNC_RESET"), .LRS_TYPE_DQ2("ASYNC_RESET"),
        .LRS_TYPE_DQ3("ASYNC_RESET"), .GRS_TYPE_TQ("RESET"),
        .LRS_TYPE_TQ0("ASYNC_RESET"), .LRS_TYPE_TQ1("ASYNC_RESET"),
        .LRS_TYPE_TQ2("ASYNC_RESET"), .LRS_TYPE_TQ3("ASYNC_RESET"),
        .TRI_EN("FALSE"), .TBYTE_EN("FALSE"), .MIPI_EN("FALSE"),
        .OCASCADE_EN("FALSE")
    ) u_master (
        .RST(lane_reset), .OCE(1'b1), .TCE(1'b0),
        .OCLKDIV(pixel_clk), .SERCLK(serial_clk), .OCLK(serial_clk),
        .MIPI_CTRL(), .UPD0_SHIFT(1'b0), .UPD1_SHIFT(1'b0),
        .OSHIFTIN0(cascade0), .OSHIFTIN1(cascade1),
        .DI(symbol[7:0]), .TI(), .TBYTE_IN(),
        .OSHIFTOUT0(), .OSHIFTOUT1(), .DO(serial_data), .TQ()
    );

    // Purpose: the slave supplies symbol bits 9:8 through the dedicated local
    // cascade. Its input placement exactly follows the vendor reference.
    GTP_OSERDES_E2 #(
        .GRS_EN("TRUE"), .OSERDES_MODE("DDR10TO1"),
        .TSERDES_EN("FALSE"), .UPD0_SHIFT_EN("FALSE"),
        .UPD1_SHIFT_EN("FALSE"), .INIT_SET(2'b00),
        .GRS_TYPE_DQ("RESET"), .LRS_TYPE_DQ0("ASYNC_RESET"),
        .LRS_TYPE_DQ1("ASYNC_RESET"), .LRS_TYPE_DQ2("ASYNC_RESET"),
        .LRS_TYPE_DQ3("ASYNC_RESET"), .GRS_TYPE_TQ("RESET"),
        .LRS_TYPE_TQ0("ASYNC_RESET"), .LRS_TYPE_TQ1("ASYNC_RESET"),
        .LRS_TYPE_TQ2("ASYNC_RESET"), .LRS_TYPE_TQ3("ASYNC_RESET"),
        .TRI_EN("FALSE"), .TBYTE_EN("FALSE"), .MIPI_EN("FALSE"),
        .OCASCADE_EN("TRUE")
    ) u_slave (
        .RST(lane_reset), .OCE(1'b1), .TCE(1'b0),
        .OCLKDIV(pixel_clk), .SERCLK(serial_clk), .OCLK(serial_clk),
        .MIPI_CTRL(), .UPD0_SHIFT(1'b0), .UPD1_SHIFT(1'b0),
        .OSHIFTIN0(), .OSHIFTIN1(),
        .DI({4'b0000, symbol[9:8], 2'b00}), .TI(), .TBYTE_IN(),
        .OSHIFTOUT0(cascade0), .OSHIFTOUT1(cascade1), .DO(), .TQ()
    );
endmodule
