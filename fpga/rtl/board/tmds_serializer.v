`timescale 1ns/1ps
// Native cascade wiring adapted from MINI 2_10_hdmi_loop/source/outputserdes.v.
// No TMDS video encoding or HDMI timing generator is implemented here.
module tmds_serializer(input wire pixel_clk, input wire serial_clk,
    input wire reset, input wire [9:0] symbol,
    output wire data_p, output wire data_n);
    wire serial_data, cascade0, cascade1;
    // A separate release FF per lane reduces the reset net to two adjacent
    // IOL loads. Its location is constrained beside that physical TMDS pair.
    // The release chain asserts asynchronously and releases on pixel_clk,
    // matching the native gear-control reset domain (OCLKDIV).
    // Use the native reference's ASYNC_RESET mode throughout the OSERDES.
    // Common-source clocks and regional routing control release skew; all
    // recovery/removal checks remain enabled, including both serial edges.
    (* syn_preserve = 1, syn_keep = 1 *) reg local_reset;
    always @(posedge pixel_clk or posedge reset)
        if (reset) local_reset <= 1'b1;
        else local_reset <= 1'b0;
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) output_buffer
        (.O(data_p), .OB(data_n), .I(serial_data));
    GTP_OSERDES_E2 #(.GRS_EN("TRUE"), .OSERDES_MODE("DDR10TO1"),
        .TSERDES_EN("FALSE"), .UPD0_SHIFT_EN("FALSE"), .UPD1_SHIFT_EN("FALSE"),
        .INIT_SET(2'b00), .GRS_TYPE_DQ("RESET"), .GRS_TYPE_TQ("RESET"),
        .LRS_TYPE_DQ0("ASYNC_RESET"), .LRS_TYPE_DQ1("ASYNC_RESET"),
        .LRS_TYPE_DQ2("ASYNC_RESET"), .LRS_TYPE_DQ3("ASYNC_RESET"),
        .LRS_TYPE_TQ0("ASYNC_RESET"), .LRS_TYPE_TQ1("ASYNC_RESET"),
        .LRS_TYPE_TQ2("ASYNC_RESET"), .LRS_TYPE_TQ3("ASYNC_RESET"),
        .TRI_EN("FALSE"), .TBYTE_EN("FALSE"), .MIPI_EN("FALSE"), .OCASCADE_EN("FALSE"))
    master(.RST(local_reset), .OCE(1'b1), .TCE(1'b0), .OCLKDIV(pixel_clk),
        .SERCLK(serial_clk), .OCLK(serial_clk), .MIPI_CTRL(1'b0),
        .UPD0_SHIFT(1'b0), .UPD1_SHIFT(1'b0), .OSHIFTIN0(cascade0),
        .OSHIFTIN1(cascade1), .DI(symbol[7:0]), .TI(8'b0), .TBYTE_IN(1'b0),
        .OSHIFTOUT0(), .OSHIFTOUT1(), .DO(serial_data), .TQ());
    GTP_OSERDES_E2 #(.GRS_EN("TRUE"), .OSERDES_MODE("DDR10TO1"),
        .TSERDES_EN("FALSE"), .UPD0_SHIFT_EN("FALSE"), .UPD1_SHIFT_EN("FALSE"),
        .INIT_SET(2'b00), .GRS_TYPE_DQ("RESET"), .GRS_TYPE_TQ("RESET"),
        .LRS_TYPE_DQ0("ASYNC_RESET"), .LRS_TYPE_DQ1("ASYNC_RESET"),
        .LRS_TYPE_DQ2("ASYNC_RESET"), .LRS_TYPE_DQ3("ASYNC_RESET"),
        .LRS_TYPE_TQ0("ASYNC_RESET"), .LRS_TYPE_TQ1("ASYNC_RESET"),
        .LRS_TYPE_TQ2("ASYNC_RESET"), .LRS_TYPE_TQ3("ASYNC_RESET"),
        .TRI_EN("FALSE"), .TBYTE_EN("FALSE"), .MIPI_EN("FALSE"), .OCASCADE_EN("TRUE"))
    slave(.RST(local_reset), .OCE(1'b1), .TCE(1'b0), .OCLKDIV(pixel_clk),
        .SERCLK(serial_clk), .OCLK(serial_clk), .MIPI_CTRL(1'b0),
        // The slave's unused cascade inputs must be open, as in the native
        // MINI reference. These dedicated pins cannot route to fabric GND.
        .UPD0_SHIFT(1'b0), .UPD1_SHIFT(1'b0), .OSHIFTIN0(), .OSHIFTIN1(),
        .DI({4'b0,symbol[9:8],2'b0}), .TI(8'b0), .TBYTE_IN(1'b0),
        .OSHIFTOUT0(cascade0), .OSHIFTOUT1(cascade1), .DO(), .TQ());
endmodule
