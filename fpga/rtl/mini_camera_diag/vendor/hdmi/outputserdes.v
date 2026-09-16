`timescale 1ns/1ps
// Purpose: adapt the vendor HDMI interface to the existing Logos2 native 10:1
// master/slave serializer, including its per-lane local reset register.
// Only KPARALLELWIDTH=10 is supported; clocks must be coherent with ratio 5:1.
module outputserdes #(parameter KPARALLELWIDTH=10)(
    input pixelclk, serialclk, rstn,
    input [KPARALLELWIDTH-1:0] pdataout,
    output sdataout_p, sdataout_n
);
    tmds_serializer u_serial(.pixel_clk(pixelclk), .serial_clk(serialclk),
        .reset(!rstn), .symbol(pdataout), .data_p(sdataout_p), .data_n(sdataout_n));
endmodule
