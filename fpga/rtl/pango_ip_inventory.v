`timescale 1ns/1ps

// Small integration harness for the native Pango IP instances used by the
// planned video path. The DDR3 instance is listed in the PDS project and is
// generated separately, but is not instantiated until the real MINI DDR
// wiring, memory part and controller parameters are confirmed.
module pango_ip_inventory (
    input  wire clk27,
    input  wire rst_n,
    input  wire key,
    output wire pll_lock,
    output wire fifo_full,
    output wire fifo_empty,
    output wire ram_bit
);
    wire clk_video;
    wire clk_mem;
    wire clk_aux;
    wire [7:0] fifo_rd_data;
    wire [8:0] fifo_wr_level;
    wire [8:0] fifo_rd_level;
    wire fifo_almost_full;
    wire fifo_almost_empty;
    wire [7:0] ram_rd_data;
    reg  [7:0] sample;
    reg  [5:0] ram_addr;

    pll u_pll (
        .clkout0 (clk_video),
        .clkout1 (clk_mem),
        .clkout2 (clk_aux),
        .lock    (pll_lock),
        .clkin1  (clk27)
    );

    fifo_test u_line_fifo (
        .wr_clk         (clk_video),
        .wr_rst         (~rst_n),
        .wr_en          (rst_n & key),
        .wr_data       (sample),
        .wr_full       (fifo_full),
        .wr_water_level (fifo_wr_level),
        .rd_clk         (clk_aux),
        .rd_rst         (~rst_n),
        .rd_en          (rst_n & ~key),
        .rd_data        (fifo_rd_data),
        .almost_full    (fifo_almost_full),
        .rd_empty       (fifo_empty),
        .rd_water_level (fifo_rd_level),
        .almost_empty   (fifo_almost_empty)
    );

    ram_test u_line_ram (
        .wr_data (sample),
        .wr_addr (ram_addr),
        .wr_en   (rst_n & key),
        .wr_clk  (clk_mem),
        .wr_rst  (~rst_n),
        .rd_data (ram_rd_data),
        .rd_addr (ram_addr),
        .rd_clk  (clk_aux),
        .rd_rst  (~rst_n)
    );

    always @(posedge clk27) begin
        if (!rst_n) begin
            sample   <= 8'h00;
            ram_addr <= 6'h00;
        end else begin
            sample   <= sample + 8'h01;
            ram_addr <= ram_addr + 6'h01;
        end
    end

    assign ram_bit = ram_rd_data[0] ^ fifo_rd_data[0];
endmodule
