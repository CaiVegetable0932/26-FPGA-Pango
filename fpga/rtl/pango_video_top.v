`timescale 1ns/1ps

// First native-PDS project integration point for the PG2L100H video design.
// The video datapath is intentionally not implemented in this baseline.
// IPs are exercised through pango_ip_inventory so the project checks their
// generated source and module interfaces before the board-specific datapath
// is connected.
module pango_video_top (
    input  wire clk27,
    input  wire rst_n,
    input  wire key,
    output wire led0
);
    wire pll_lock;
    wire fifo_full;
    wire fifo_empty;
    wire ram_bit;

    pango_ip_inventory u_ip_inventory (
        .clk27      (clk27),
        .rst_n      (rst_n),
        .key        (key),
        .pll_lock   (pll_lock),
        .fifo_full  (fifo_full),
        .fifo_empty (fifo_empty),
        .ram_bit    (ram_bit)
    );

    // Visible status only: the LED is not a video-result indicator.
    assign led0 = rst_n & pll_lock & ~fifo_full & ~fifo_empty & ram_bit;
endmodule
