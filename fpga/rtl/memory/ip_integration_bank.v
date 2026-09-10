`timescale 1ns/1ps
// Build-only integration harness, not an ISP/DMA/video datapath.
// Every selected memory/APM IP has a real elaborated instance and an observable
// output. No synthetic frame generator, memory test or traffic generator exists.
// DDR reads and incoming RX data are the only possible sample sources.
module ip_integration_bank(
    input wire proc_clk, input wire ddr_clk, input wire pixel_clk, input wire tx_clk,
    input wire rx_clk, input wire proc_reset_n, input wire ddr_reset_n,
    input wire pixel_reset_n, input wire tx_reset_n, input wire rx_reset_n,
    input wire [7:0] rx_data, input wire rx_valid,
    input wire [255:0] ddr_data, input wire ddr_valid,
    output wire [255:0] write_data,
    output reg proc_observe, output reg ddr_observe,
    output reg pixel_observe, output reg tx_observe
);
    wire [7:0] raw_data, packet_data;
    wire raw_full, raw_empty, packet_full, packet_empty;
    raw_async_fifo u_raw_fifo(.wr_clk(rx_clk), .wr_rst(!rx_reset_n),
        .wr_en(rx_valid && !raw_full), .wr_data(rx_data), .wr_full(raw_full),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n), .rd_en(!raw_empty),
        .rd_data(raw_data), .rd_empty(raw_empty), .wr_water_level(),
        .rd_water_level(), .almost_full(), .almost_empty());
    net_tx_fifo u_packet_fifo(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!raw_empty && !packet_full), .wr_data(raw_data), .wr_full(packet_full),
        .rd_clk(tx_clk), .rd_rst(!tx_reset_n), .rd_en(!packet_empty),
        .rd_data(packet_data), .rd_empty(packet_empty), .almost_full(), .almost_empty());
    wire [31:0] read_data, line_data, cache_data, param_a, param_b, display_data;
    wire read_full, read_empty, write_full, write_empty, display_full, display_empty;
    ddr_read_fifo u_read_fifo(.wr_clk(ddr_clk), .wr_rst(!ddr_reset_n),
        .wr_en(ddr_valid && !read_full), .wr_data(ddr_data), .wr_full(read_full),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n), .rd_en(!read_empty),
        .rd_data(read_data), .rd_empty(read_empty), .almost_full(), .almost_empty());
    ddr_write_fifo u_write_fifo(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty && !write_full), .wr_data(read_data), .wr_full(write_full),
        .rd_clk(ddr_clk), .rd_rst(!ddr_reset_n), .rd_en(!write_empty),
        .rd_data(write_data), .rd_empty(write_empty), .almost_full(), .almost_empty());
    reg [14:0] sample_addr;
    always @(posedge proc_clk or negedge proc_reset_n)
        if (!proc_reset_n) sample_addr <= 15'b0;
        else if (!read_empty) sample_addr <= sample_addr + 1'b1;
    isp_line_ram u_line_ram(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty), .wr_addr(sample_addr[10:0]), .wr_data(read_data),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n),
        .rd_addr(sample_addr[10:0]), .rd_data(line_data));
    tile_cache_ram u_cache_ram(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty), .wr_addr(sample_addr), .wr_data(read_data),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n), .rd_addr(sample_addr), .rd_data(cache_data));
    parameter_ram u_parameter_ram(.a_clk(proc_clk), .a_rst(!proc_reset_n),
        .a_wr_en(!raw_empty), .a_addr(sample_addr[9:0]), .a_wr_data(read_data), .a_rd_data(param_a),
        .b_clk(proc_clk), .b_rst(!proc_reset_n), .b_wr_en(1'b0),
        .b_addr(read_data[9:0]), .b_wr_data(32'b0), .b_rd_data(param_b));
    wire [7:0] gamma_data;
    gamma_rom u_gamma_rom(.clk(proc_clk), .rst(!proc_reset_n),
        .addr({sample_addr[0],raw_data}), .rd_data(gamma_data));
    wire [42:0] geometry_product;
    wire [27:0] interpolation_sum;
    wire [47:0] accumulated_product;
    geometry_mult u_geometry_mult(.clk(proc_clk), .rst(!proc_reset_n), .ce(1'b1),
        .a(line_data[24:0]), .b(param_a[17:0]), .p(geometry_product));
    bilinear_multadd u_bilinear_multadd(.clk(proc_clk), .rst(!proc_reset_n), .ce(1'b1),
        .a0(cache_data[17:0]), .a1(param_b[17:0]), .b0(read_data[8:0]),
        .b1(read_data[17:9]), .p(interpolation_sum));
    statistics_mac u_statistics_mac(.clk(proc_clk), .rst(!proc_reset_n), .ce(!read_empty),
        .a(read_data[15:0]), .b(read_data[31:16]), .acc_init(48'b0),
        .reload(!proc_reset_n), .p(accumulated_product));
    display_fifo u_display_fifo(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty && !display_full), .wr_data(cache_data), .wr_full(display_full),
        .rd_clk(pixel_clk), .rd_rst(!pixel_reset_n), .rd_en(!display_empty),
        .rd_data(display_data), .rd_empty(display_empty), .almost_full(), .almost_empty());
    // Register observations before their single-bit status synchronizers.
    // These are activity indicators, never frame/data integrity measurements.
    always @(posedge proc_clk or negedge proc_reset_n)
        if (!proc_reset_n) proc_observe <= 1'b0;
        else proc_observe <= ^{geometry_product,interpolation_sum,accumulated_product,gamma_data,param_a,param_b,line_data,cache_data};
    always @(posedge ddr_clk or negedge ddr_reset_n)
        if (!ddr_reset_n) ddr_observe <= 1'b0;
        else ddr_observe <= ^write_data ^ write_empty;
    always @(posedge pixel_clk or negedge pixel_reset_n)
        if (!pixel_reset_n) pixel_observe <= 1'b0;
        else pixel_observe <= ^display_data ^ display_empty;
    always @(posedge tx_clk or negedge tx_reset_n)
        if (!tx_reset_n) tx_observe <= 1'b0;
        else tx_observe <= ^packet_data ^ packet_empty;
endmodule
