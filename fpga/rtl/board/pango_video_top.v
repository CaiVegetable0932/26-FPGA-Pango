`timescale 1ns/1ps
// 模块用途：pango_video_top 是 PG2L100H MINI 板的烧录前工程集成顶层，
// 连接时钟/复位、DDR3、RGMII、HDMI 串行器与候选存储/运算 IP，供 PDS 完成构建。
// 时钟与复位：125 MHz 差分参考产生系统/处理/网口时钟，27 MHz 参考产生视频时钟；
// 各业务域独立同步释放低有效复位，DDR 业务域还需等待原生控制器初始化完成。
// 当前边界：未实现摄像头、ISP、帧池 DMA、网络协议或几何矫正。
// DDR 地址请求空闲、PHY 始终复位；HDMI 已接入共用发送器，输出显式 720p 自检图。
// 本模块仅用于构建集成；未经板卡、引脚极性和接口延时专项复核，不得烧录此位流。
module pango_video_top(
    // 板载参考时钟和低有效外部复位；LED 仅汇总内部观察位。
    input wire clk_27m, input wire ref_clk_p, input wire ref_clk_n, input wire reset_n,
    output wire status_led,
    // 板载以太网 PHY 的 RGMII 数据接口及复位/管理接口，当前不启用业务通信。
    input wire rgmii_rxc, input wire [3:0] rgmii_rxd, input wire rgmii_rx_ctl,
    output wire rgmii_txc, output wire [3:0] rgmii_txd, output wire rgmii_tx_ctl,
    output wire phy_reset_n, output wire phy_mdc, inout wire phy_mdio,
    // 唯一 HDMI 输出：一对 TMDS 时钟与三对 TMDS 数据，不包含视频源输入。
    output wire hdmi_clk_p, output wire hdmi_clk_n,
    output wire [2:0] hdmi_data_p, output wire [2:0] hdmi_data_n,
    // 32-bit DDR3 物理接口直接交由原生控制器/PHY 驱动，管脚由板级约束确定。
    output wire mem_cs_n, output wire mem_rst_n, output wire mem_ck, output wire mem_ck_n,
    output wire mem_cke, output wire mem_ras_n, output wire mem_cas_n,
    output wire mem_we_n, output wire mem_odt, output wire [14:0] mem_a,
    output wire [2:0] mem_ba, inout wire [3:0] mem_dqs, inout wire [3:0] mem_dqs_n,
    inout wire [31:0] mem_dq, output wire [3:0] mem_dm
);
    wire ref_clk, sys_clk, proc_clk, tx_clk, pixel_clk, serial_clk;
    wire sys_lock, video_lock;
    // 差分输入原语将板载 125 MHz 参考送入系统 PLL 和 DDR3 控制器。
    GTP_INBUFDS #(.IOSTANDARD("DEFAULT")) u_ref_input(.I(ref_clk_p), .IB(ref_clk_n), .O(ref_clk));
    // sys_pll：产生 100 MHz 系统、150 MHz 处理和 125 MHz RGMII 发送时钟。
    sys_pll u_sys_pll(.clkin1(ref_clk), .clkout0(sys_clk),
        .clkout1(proc_clk), .clkout2(tx_clk), .lock(sys_lock));
    // Keep main's native single-source I/O clock topology, replacing only its
    // failed generated PLL with the board-proven vendor PLL's 371.25 MHz output.
    // The native /5 aligns the parallel/serial IOL clocks (40% pixel duty).
    wire hdmi_serial_clk, hdmi_div_reset_n;
    clk_hdmi u_video_pll(.clkin1(clk_27m), .clkout0(),
        .clkout1(serial_clk), .lock(video_lock));
    GTP_CLKBUFR u_hdmi_serial_clock(.CLKIN(serial_clk), .CLKOUT(hdmi_serial_clk));
    reset_sync rs_hdmi_div(hdmi_serial_clk, reset_n && video_lock, hdmi_div_reset_n);
    GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_hdmi_pixel_div(
        .CLKIN(serial_clk), .RST_N(hdmi_div_reset_n), .CE(1'b1), .CLKDIVOUT(pixel_clk));
    wire sys_reset_n, proc_reset_n, tx_reset_n, pixel_reset_n, ddr_reset_n, rx_reset_n;
    wire ddr_clk, ddr_ready, ddr_lock;
    // 每个时钟域分别异步置复位、同步释放；不能把一个域释放后的复位直接跨域使用。
    // ddr_ready 只约束用户侧集成逻辑，不用于复位控制器自身，以免阻止 DDR 初始化。
    reset_sync rs_sys(sys_clk, reset_n && sys_lock, sys_reset_n);
    reset_sync rs_proc(proc_clk, reset_n && sys_lock, proc_reset_n);
    reset_sync rs_tx(tx_clk, reset_n && sys_lock, tx_reset_n);
    // Common delayed pixel-domain reset also responds to the board pushbutton.
    hdmi_tx_powerup_reset u_hdmi_reset(.pixel_clk(pixel_clk),
        .pll_locked(reset_n && video_lock), .reset_n(pixel_reset_n));
    reset_sync rs_ddr(ddr_clk, reset_n && ddr_lock && ddr_ready, ddr_reset_n);
    wire [255:0] ddr_rdata, ddr_wdata;
    wire ddr_rvalid;
    // ddr3_controller：原生 DDR3 控制器/PHY，当前候选配置为 32-bit DDR、256-bit 用户数据口。
    // I_ips_ddr_top 实例名与原生约束层级绑定，修改名称时必须同步核对约束。
    // AW/AR valid 与 APB 选择信号均为 0：只保留接口集成，不发起存储器读写或寄存器访问；
    // 即使 write_data 变化，也不代表已执行写事务；DDR 颗粒参数与板级连线仍待实物签核。
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
    // RGMII 物理转换层保留原生双沿输入/输出原语；发送数据与有效信号均置零。
    // 接收字节只作为集成库的候选输入，不代表已具备 MAC、报文解析或摄像头 RAW8 输入。
    rgmii_phy_io u_rgmii(.tx_clk(tx_clk), .reset(!reset_n), .tx_data(8'b0), .tx_valid(1'b0),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .rx_clk(rx_clk), .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error),
        .rgmii_txc(rgmii_txc), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl));
    reset_sync rs_rx(rx_clk, reset_n, rx_reset_n);
    // 暂不释放 PHY，也不执行 MDIO 管理访问，避免在延时/strap 配置未核对时启用链路。
    assign phy_reset_n = 1'b0;
    assign phy_mdc = 1'b0;
    assign phy_mdio = 1'bz;
    wire proc_observe, ddr_observe, pixel_observe, tx_observe;
    // 集成库实例化其余 12 个 FIFO/RAM/ROM/运算 IP，输出回接 DDR 数据口及域内观察位。
    // 这里的样本连接仅服务于构建，不是最终 ISP、帧池调度或网络/显示数据通路。
    ip_integration_bank u_ip_bank(.proc_clk(proc_clk), .ddr_clk(ddr_clk), .pixel_clk(pixel_clk),
        .tx_clk(tx_clk), .rx_clk(rx_clk), .proc_reset_n(proc_reset_n), .ddr_reset_n(ddr_reset_n),
        .pixel_reset_n(pixel_reset_n), .tx_reset_n(tx_reset_n), .rx_reset_n(rx_reset_n),
        .rx_data(rx_data), .rx_valid(rx_valid && !rx_error), .ddr_data(ddr_rdata), .ddr_valid(ddr_rvalid),
        .write_data(ddr_wdata), .proc_observe(proc_observe), .ddr_observe(ddr_observe),
        .pixel_observe(pixel_observe), .tx_observe(tx_observe));
    // Explicit diagnostic source while RAW8/ISP is not implemented in this shell.
    // Real camera DDR output in mini_camera_diag uses the SAME hdmi_tx_rgb sink.
    // Future S2/S3 scanout must supply RGB888 + aligned DE/HS/VS in pixel_clk.
    wire [23:0] display_rgb;
    wire display_de, display_hs, display_vs;
    hdmi_720p_diagnostic u_hdmi_diagnostic(.pixel_clk(pixel_clk),
        .reset_n(pixel_reset_n), .rgb(display_rgb), .de(display_de),
        .hs(display_hs), .vs(display_vs));
    hdmi_tx_rgb u_hdmi_tx(.pixel_clk(pixel_clk), .serial_clk(hdmi_serial_clk),
        .reset_n(pixel_reset_n), .rgb(display_rgb), .data_enable(display_de),
        .hsync(display_hs), .vsync(display_vs), .tmds_clk_p(hdmi_clk_p),
        .tmds_clk_n(hdmi_clk_n), .tmds_data_p(hdmi_data_p), .tmds_data_n(hdmi_data_n));
    // 各观察位独立经两级寄存进入系统域，降低单比特跨域的亚稳态传播风险。
    // 这不是六位总线的原子快照，也不能保证捕获每次活动；异或 LED 不表示数据正确或测试通过。
    (* syn_preserve = 1 *) reg [5:0] status_meta, status_sync;
    always @(posedge sys_clk or negedge sys_reset_n)
        if (!sys_reset_n) begin status_meta <= 6'b0; status_sync <= 6'b0; end
        else begin
            status_meta <= {proc_observe, ddr_observe, pixel_observe, tx_observe, ddr_ready, video_lock};
            status_sync <= status_meta;
        end
    assign status_led = ^status_sync;
endmodule
