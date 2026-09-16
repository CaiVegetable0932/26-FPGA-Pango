`timescale 1ns/1ps
// PRE-PROGRAMMING INTEGRATION ONLY. Not a functioning camera/video system.
// DDR requests are held idle; PHY reset remains asserted; HDMI emits blanking.
// Do not program this image before a separate board/polarity/delay review.
module pango_video_top(
    input wire clk_27m, input wire ref_clk_p, input wire ref_clk_n, input wire reset_n,
    output wire status_led,
    input wire rgmii_rxc, input wire [3:0] rgmii_rxd, input wire rgmii_rx_ctl,
    output wire rgmii_txc, output wire [3:0] rgmii_txd, output wire rgmii_tx_ctl,
    output wire phy_reset_n, output wire phy_mdc, inout wire phy_mdio,
    output wire hdmi_clk_p, output wire hdmi_clk_n,
    output wire [2:0] hdmi_data_p, output wire [2:0] hdmi_data_n,
    output wire mem_cs_n, output wire mem_rst_n, output wire mem_ck, output wire mem_ck_n,
    output wire mem_cke, output wire mem_ras_n, output wire mem_cas_n,
    output wire mem_we_n, output wire mem_odt, output wire [14:0] mem_a,
    output wire [2:0] mem_ba, inout wire [3:0] mem_dqs, inout wire [3:0] mem_dqs_n,
    inout wire [31:0] mem_dq, output wire [3:0] mem_dm
);
    wire ref_clk, sys_refclk, sys_clk, proc_clk, tx_clk, pixel_clk, serial_clk;
    wire sys_lock, video_lock;
    GTP_INBUFDS #(.IOSTANDARD("DEFAULT")) u_ref_input(.I(ref_clk_p), .IB(ref_clk_n), .O(ref_clk));
    // DDR retains its dedicated MRCKB reference path. The independent system
    // PLL uses a global reference buffer to cross to the other clock region.
    GTP_CLKBUFG u_system_reference(.CLKIN(ref_clk), .CLKOUT(sys_refclk));
    sys_pll u_sys_pll(.clkin1(sys_refclk), .clkout0(sys_clk),
        .clkout1(proc_clk), .clkout2(tx_clk), .lock(sys_lock));
    video_pll u_video_pll(.clkin1(clk_27m), .clkout0(pixel_clk),
        .clkout1(serial_clk), .lock(video_lock));
    wire sys_reset_n, proc_reset_n, tx_reset_n, pixel_reset_n, ddr_reset_n, rx_reset_n;
    wire ddr_clk, ddr_ready, ddr_lock;
    reset_sync rs_sys(sys_clk, reset_n && sys_lock, sys_reset_n);
    reset_sync rs_proc(proc_clk, reset_n && sys_lock, proc_reset_n);
    reset_sync rs_tx(tx_clk, reset_n && sys_lock, tx_reset_n);
    reset_sync rs_pixel(pixel_clk, reset_n && video_lock, pixel_reset_n);
    reset_sync rs_ddr(ddr_clk, reset_n && ddr_lock && ddr_ready, ddr_reset_n);
    wire [255:0] ddr_rdata, ddr_wdata;
    wire ddr_rvalid;
    // Instance name matches the native DDR constraint hierarchy.
    ddr3_controller I_ips_ddr_top(
        .ref_clk(ref_clk), .resetn(reset_n), .core_clk(ddr_clk), .pll_lock(ddr_lock),
        .phy_pll_lock(), .gpll_lock(), .rst_gpll_lock(), .ddrphy_cpd_lock(), .ddr_init_done(ddr_ready),
        .axi_awaddr(28'b0), .axi_awuser_ap(1'b0), .axi_awuser_id(4'b0),
        .axi_awlen(4'b0), .axi_awready(), .axi_awvalid(1'b0),
        .axi_wdata(ddr_wdata), .axi_wstrb(32'hffffffff), .axi_wready(), .axi_wusero_id(), .axi_wusero_last(),
        .axi_araddr(28'b0), .axi_aruser_ap(1'b0), .axi_aruser_id(4'b0),
        .axi_arlen(4'b0), .axi_arready(), .axi_arvalid(1'b0),
        .axi_rdata(ddr_rdata), .axi_rid(), .axi_rlast(), .axi_rvalid(ddr_rvalid),
        .apb_clk(sys_clk), .apb_rst_n(sys_reset_n), .apb_sel(1'b0), .apb_enable(1'b0),
        .apb_addr(8'b0), .apb_write(1'b0), .apb_ready(), .apb_wdata(16'b0), .apb_rdata(),
        .mem_cs_n(mem_cs_n), .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n),
        .mem_we_n(mem_we_n), .mem_odt(mem_odt), .mem_a(mem_a), .mem_ba(mem_ba),
        .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n), .mem_dq(mem_dq), .mem_dm(mem_dm),
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0), .dbg_ddrphy_rst_n(1'b1), .dbg_gpll_scan_rst(1'b0),
        .samp_position_dyn_adj(1'b0), .init_samp_position_even(32'b0), .init_samp_position_odd(32'b0),
        .wrcal_position_dyn_adj(1'b0), .init_wrcal_position(32'b0), .force_read_clk_ctrl(1'b0),
        .init_slip_step(16'b0), .init_read_clk_ctrl(12'b0), .debug_calib_ctrl(),
        .dbg_slice_status(), .dbg_slice_state(), .debug_data(), .dbg_dll_upd_state(),
        .debug_gpll_dps_phase(), .dbg_rst_dps_state(), .dbg_tran_err_rst_cnt(), .dbg_ddrphy_init_fail(),
        .debug_cpd_offset_adj(1'b0), .debug_cpd_offset_dir(1'b0), .debug_cpd_offset(10'b0),
        .debug_dps_cnt_dir0(), .debug_dps_cnt_dir1(), .ck_dly_en(1'b0),
        .init_ck_dly_step(8'b0), .ck_dly_set_bin(), .align_error(), .debug_rst_state(), .debug_cpd_state());
    wire rx_clk, rx_valid, rx_error;
    wire [7:0] rx_data;
    rgmii_phy_io u_rgmii(.tx_clk(tx_clk), .reset(!reset_n), .tx_data(8'b0), .tx_valid(1'b0),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .rx_clk(rx_clk), .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error),
        .rgmii_txc(rgmii_txc), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl));
    reset_sync rs_rx(rx_clk, reset_n, rx_reset_n);
    assign phy_reset_n = 1'b0;
    assign phy_mdc = 1'b0;
    assign phy_mdio = 1'bz;
    wire proc_observe, ddr_observe, pixel_observe, tx_observe;
    ip_integration_bank u_ip_bank(.proc_clk(proc_clk), .ddr_clk(ddr_clk), .pixel_clk(pixel_clk),
        .tx_clk(tx_clk), .rx_clk(rx_clk), .proc_reset_n(proc_reset_n), .ddr_reset_n(ddr_reset_n),
        .pixel_reset_n(pixel_reset_n), .tx_reset_n(tx_reset_n), .rx_reset_n(rx_reset_n),
        .rx_data(rx_data), .rx_valid(rx_valid && !rx_error), .ddr_data(ddr_rdata), .ddr_valid(ddr_rvalid),
        .write_data(ddr_wdata), .proc_observe(proc_observe), .ddr_observe(ddr_observe),
        .pixel_observe(pixel_observe), .tx_observe(tx_observe));
    // DIAGNOSTIC ONLY: isolate serializer routing, never generate a bitstream.
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_clk (.I(pixel_clk), .O(hdmi_clk_p), .OB(hdmi_clk_n));
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_d0 (.I(pixel_clk), .O(hdmi_data_p[0]), .OB(hdmi_data_n[0]));
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_d1 (.I(pixel_clk), .O(hdmi_data_p[1]), .OB(hdmi_data_n[1]));
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_d2 (.I(pixel_clk), .O(hdmi_data_p[2]), .OB(hdmi_data_n[2]));
    (* syn_preserve = 1 *) reg [5:0] status_meta, status_sync;
    always @(posedge sys_clk or negedge sys_reset_n)
        if (!sys_reset_n) begin status_meta <= 6'b0; status_sync <= 6'b0; end
        else begin
            status_meta <= {proc_observe, ddr_observe, pixel_observe, tx_observe, ddr_ready, video_lock};
            status_sync <= status_meta;
        end
    assign status_led = ^status_sync;
endmodule
