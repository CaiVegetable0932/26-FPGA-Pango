`timescale 1ns/1ps
// Purpose: convert 24-bit RGB and blanking controls to three TMDS data lanes
// plus the forwarded pixel-clock lane. All four serializers share one reset so
// their 10-bit word boundaries begin together, matching the MINI reference.
module hdmi_tx_rgb(
    input  wire        pixel_clk,
    input  wire        serial_clk,
    input  wire        reset_n,
    input  wire [23:0] rgb,
    input  wire        data_enable,
    input  wire        hsync,
    input  wire        vsync,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n
);
    wire [9:0] encoded [2:0];


    // Purpose: lane zero transports blue and the horizontal/vertical control
    // bits during blanking; green and red lanes use control value 00.
    tmds_encoder u_blue_encoder(
        .pix_clk(pixel_clk), .rstn(reset_n), .din(rgb[7:0]),
        .c0(hsync), .c1(vsync), .de(data_enable), .dout(encoded[0])
    );
    tmds_encoder u_green_encoder(
        .pix_clk(pixel_clk), .rstn(reset_n), .din(rgb[15:8]),
        .c0(1'b0), .c1(1'b0), .de(data_enable), .dout(encoded[1])
    );
    tmds_encoder u_red_encoder(
        .pix_clk(pixel_clk), .rstn(reset_n), .din(rgb[23:16]),
        .c0(1'b0), .c1(1'b0), .de(data_enable), .dout(encoded[2])
    );

    // Purpose: 1111100000 produces the required forwarded pixel clock when the
    // native serializer transmits bit zero first, as in the vendor chain.
    hdmi_tx_oserdes u_clock_lane(
        .pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .reset_n(reset_n), .symbol(10'b1111100000),
        .data_p(tmds_clk_p), .data_n(tmds_clk_n)
    );

    genvar lane;
    generate
        for (lane = 0; lane < 3; lane = lane + 1) begin : g_data_lanes
            hdmi_tx_oserdes u_data_lane(
                .pixel_clk(pixel_clk), .serial_clk(serial_clk),
                .reset_n(reset_n), .symbol(encoded[lane]),
                .data_p(tmds_data_p[lane]), .data_n(tmds_data_n[lane])
            );
        end
    endgenerate
endmodule
