// Purpose: isolated PG2L100H gray geometry candidate. Captured/enhanced RAW8
// Ethernet remains unchanged; HDMI reads fenced gray correction result slots.
// Does not change the stable mini_raw8_dual target or program physical hardware.
// DDR native core is 125 MHz, shared with UART/MDIO/MAC. An entire-packet
// native FIFO bridge feeds RGMII from a separate board-proven 125 MHz PLL.
// Sensor SCCB stays on 27 MHz and HDMI on the proven 74.25/371.25 MHz pair.
// A RAW8 commissioning ACK is not proof of a live camera; only validated stored
// frames are sent. This top contains no synthetic video source or fallback.
module mini_raw8_geometry(
 input wire sys_clk,clk_p,clk_n,rst_in,
 input wire camera_clk_0,camera_vsync_0,camera_href_0,input wire [7:0] camera_data_0,
 inout wire SCL_0,SDA_0,output wire cam_rst_0,
 output wire [2:0] tmds_data_p,tmds_data_n,output wire tmds_clk_p,tmds_clk_n,
 input wire uart_rx,output wire uart_tx,
 output wire phy_reset_n,phy_mdc,inout wire phy_mdio,
 output wire rgmii_txc,rgmii_tx_ctl,output wire [3:0] rgmii_txd,output wire [4:0] led,
 output wire mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_cs_n,mem_ras_n,mem_cas_n,mem_we_n,mem_odt,
 output wire [14:0] mem_a,output wire [2:0] mem_ba,output wire [3:0] mem_dm,
 inout wire [3:0] mem_dqs,mem_dqs_n,inout wire [31:0] mem_dq
);
 wire clk_125Mhz,core_clk,ddr_init_done;
 wire eth_raw,eth_clk,eth_locked,eth_reset_n,eth_tx_reset_n;
 // Purpose: retain a distinct, low-load physical clock branch for the RGMII
 // serializers. This is the SAME PLL output/frequency/phase as eth_clk, not
 // an asynchronous clock or an extra PHY TX delay (TXID remains enabled).
 // Installed ADS Synthesis User Guide 5.11 documents syn_keep for net names;
 // native map/STA must separately prove that both clock buffers are retained.
 wire eth_tx_clk /* synthesis syn_keep=1 */;
 wire bridge_wr_fault,bridge_rd_fault;
 (* syn_preserve=1 *) reg bridge_meta,bridge_sync;
 wire bridge_fault=bridge_wr_fault || bridge_sync;
 wire pll_lock,phy_pll_lock,gpll_lock,rst_gpll_lock,ddrphy_cpd_lock;
 GTP_INBUFGDS #(.IOSTANDARD("DEFAULT"),.TERM_DIFF("ON")) u_gtp(
  .O(clk_125Mhz),.I(clk_p),.IB(clk_n));
 // Purpose: use the proven uncompensated networking PLL for source-synchronous
 // pins, independent of HMIC feedback compensation. Only packet FIFO/control
 // synchronizers cross between these two nominal 125 MHz domains.
 comms_pll u_eth_pll(.clkin1(clk_125Mhz),.rst(!rst_in),.clkout0(eth_raw),.clkout1(),.lock(eth_locked));
 GTP_CLKBUFG u_eth_clock(.CLKIN(eth_raw),.CLKOUT(eth_clk));
 // Purpose: separate the six pad serializers from the heavily loaded packet
 // fabric clock tree, reducing data/TXC branch skew without changing byte
 // latency, reset protocol or nominal PHY sampling phase. Related-clock
 // setup/hold and reset recovery/removal remain subject to native final STA.
 GTP_CLKBUFG u_eth_tx_clock(.CLKIN(eth_raw),.CLKOUT(eth_tx_clk));
 wire pclk,pclkx5,serial_raw,locked0,hdmi_div_reset_n,video_powerup_n;
 wire sys_reset_n,mem_reset_n,cam_reset_n,pixel_reset_n;
 clk_hdmi u_video_pll(.clkin1(sys_clk),.clkout0(),.clkout1(serial_raw),.lock(locked0));
 GTP_CLKBUFR u_hdmi_serial_clock(.CLKIN(serial_raw),.CLKOUT(pclkx5));
 reset_sync rs_hdmi_div(pclkx5,rst_in && locked0,hdmi_div_reset_n);
 GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_hdmi_pixel_div(
  .CLKIN(serial_raw),.RST_N(hdmi_div_reset_n),.CE(1'b1),.CLKDIVOUT(pclk));
 hdmi_tx_powerup_reset u_hdmi_reset(.pixel_clk(pclk),.pll_locked(rst_in && locked0),.reset_n(video_powerup_n));
 reset_sync rs_sys(sys_clk,rst_in,sys_reset_n);
 // Assert the bridge's two FIFO resets together on either clock-domain loss;
 // release each synchronously. No one-sided pointer reset is permitted.
 reset_sync rs_mem(core_clk,rst_in && ddr_init_done && locked0 && eth_locked,mem_reset_n);
 reset_sync rs_eth(eth_clk,rst_in && ddr_init_done && locked0 && eth_locked,eth_reset_n);
 // Purpose: release the RGMII pad serializers after the ETH/FIFO domain is
 // ready, using a local reset tree instead of the high-fanout FIFO reset net.
 // Assertion remains asynchronous; the extra release cycles cannot expose a
 // partial packet because commissioning starts only after board startup.
 reset_sync rs_eth_tx(eth_clk,eth_reset_n,eth_tx_reset_n);
 reset_sync rs_camera(camera_clk_0,rst_in && ddr_init_done && locked0 && eth_locked,cam_reset_n);
 reset_sync rs_pixel(pclk,rst_in && ddr_init_done && video_powerup_n && eth_locked,pixel_reset_n);
 always @(posedge core_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin bridge_meta<=0;bridge_sync<=0;end
  else begin bridge_meta<=bridge_rd_fault;bridge_sync<=bridge_meta;end
 wire sensor_ready,sensor_failed;wire [3:0] sensor_error;wire [6:0] verify_index;wire [7:0] last_read;
 ov5640_raw8_startup u_sensor(.clk(sys_clk),.rst_n(sys_reset_n),.scl(SCL_0),.sda(SDA_0),
  .reset_n(cam_rst_0),.ready(sensor_ready),.failed(sensor_failed),
  .error_code(sensor_error),.verify_index(verify_index),.last_read(last_read));
 wire sampled_vsync,sampled_href;wire [7:0] sampled_data;
 mini_dvp_input u_dvp_input(.clk(camera_clk_0),.reset_n(cam_reset_n),
  .vsync(camera_vsync_0),.href(camera_href_0),.data(camera_data_0),
  .sampled_vsync(sampled_vsync),.sampled_href(sampled_href),.sampled_data(sampled_data));
 wire mdio_o,mdio_oe,phy_configured,link_ready,phy_fault;
 wire [3:0] phy_fault_code;wire [15:0] phy_status,phy_last_read;wire [31:0] phy_id;
 wire [4:0] phy_address;wire [5:0] phy_step;wire phy_last_ack;
 assign phy_mdio=mdio_oe?mdio_o:1'bz;
 rtl8211f_init #(.PHY_TX_DELAY(1),.SCAN_ADDRESSES(1)) u_phy(.clk(core_clk),.reset_n(mem_reset_n),
  .mdio_i(phy_mdio),.mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(phy_mdc),.phy_reset_n(phy_reset_n),
  .configured(phy_configured),.link_ready(link_ready),.fault(phy_fault),.fault_code(phy_fault_code),
  .phy_status(phy_status),.phy_id(phy_id),.selected_addr(phy_address),.diagnostic_step(phy_step),
  .last_read(phy_last_read),.last_ack_error(phy_last_ack));
 wire commissioned,mcu_tx;wire [63:0] epoch;wire [47:0] src_mac,dst_mac;
 wire [31:0] src_ip,dst_ip;wire [15:0] src_port,dst_port;
 comms_boot_config #(.BOOT_COMMAND(8'h71),.BOOT_MARKER(32'h38574152)) u_boot(
  .clk(core_clk),.reset_n(mem_reset_n),.uart_rx(uart_rx),.mcu_tx(mcu_tx),.uart_tx(uart_tx),
  .configured(commissioned),.epoch(epoch),.src_mac(src_mac),.dst_mac(dst_mac),
  .src_ip(src_ip),.dst_ip(dst_ip),.src_port(src_port),.dst_port(dst_port));
 wire [27:0] axi_awaddr,axi_araddr;wire [3:0] axi_awlen,axi_arlen,axi_arid,axi_rid,axi_wid;
 wire [3:0] axi_awid=4'b0;
 wire axi_awvalid,axi_awready,axi_wready,axi_wlast,axi_arvalid,axi_arready,axi_rvalid,axi_rlast;
 wire [255:0] axi_wdata,axi_rdata;wire [31:0] axi_wstrb;
 wire [23:0] rgb;wire hs,vs,de,core_fault,gmii_en,gmii_error;wire [7:0] gmii_data;
 wire [31:0] published,underflows;wire [7:0] core_fault_detail;
 // Purpose: sticky memory-domain record fault snapshot for read-only UART06.
 wire [95:0] writer_snapshot;
 // Purpose: coherent camera snapshots and memory-domain progress via UART7..9.
 wire [287:0] chain_diagnostics;
 // Purpose: same-clock, CRC/session admitted geometry and MCU context.
 wire geo_cmd_valid,env_valid;wire [7:0] geo_cmd,geo_code;wire [255:0] geo_payload;
 wire [95:0] geo_reply;wire [31:0] mcu_session_id,env_seq;
 wire [63:0] env_time;wire signed [31:0] env_angle;wire [1:0] env_measurement;
 // UART commits payload before its CRC bytes; enable address-only reply
 // predecode while preserving the live acceptance-edge metadata snapshot.
 raw8_geometry_core #(.PREDECODE_VIEW_READ(1)) u_core(.mem_clk(core_clk),.mem_reset_n(mem_reset_n),
  .cam_clk(camera_clk_0),.cam_reset_n(cam_reset_n),.pixel_clk(pclk),.pixel_reset_n(pixel_reset_n),
  .configured(sensor_ready),.vsync(sampled_vsync),.href(sampled_href),.camera_data(sampled_data),
  .commissioned(commissioned),.network_enable(commissioned && link_ready && phy_configured && !phy_fault && !bridge_fault),
  .epoch(epoch),.src_mac(src_mac),.dst_mac(dst_mac),.src_ip(src_ip),.dst_ip(dst_ip),.src_port(src_port),.dst_port(dst_port),
  .awaddr(axi_awaddr),.araddr(axi_araddr),.awlen(axi_awlen),.arlen(axi_arlen),.arid(axi_arid),
  .awvalid(axi_awvalid),.arvalid(axi_arvalid),.awready(axi_awready),.arready(axi_arready),
  .wready(axi_wready),.wlast(axi_wlast),.wid(axi_wid),.rid(axi_rid),.rvalid(axi_rvalid),.rlast(axi_rlast),
  .rdata(axi_rdata),.wdata(axi_wdata),.wstrb(axi_wstrb),.rgb(rgb),.hs(hs),.vs(vs),.de(de),
  .gmii_data(gmii_data),.gmii_en(gmii_en),.gmii_error(gmii_error),.fault(core_fault),.published(published),.underflows(underflows),
  .fault_detail(core_fault_detail),.writer_snapshot(writer_snapshot),.chain_diagnostics(chain_diagnostics),
  .geo_cmd_valid(geo_cmd_valid),.geo_cmd(geo_cmd),.geo_payload(geo_payload),.geo_code(geo_code),.geo_reply(geo_reply),
  .mcu_context_valid(mcu_active),.mcu_session_id(mcu_session_id),.env_valid(env_valid),
  .env_measurement_valid(env_measurement),.env_angle_mdeg(env_angle),.env_event_seq(env_seq),.env_board_time_us(env_time));
 hdmi_tx_rgb u_hdmi_tx(.pixel_clk(pclk),.serial_clk(pclkx5),.reset_n(pixel_reset_n),
  .rgb(rgb),.data_enable(de),.hsync(hs),.vsync(vs),.tmds_data_p(tmds_data_p),
  .tmds_data_n(tmds_data_n),.tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n));
 wire [7:0] eth_data;wire eth_en,eth_error;
 raw8_gmii_cdc u_gmii_bridge(.wr_clk(core_clk),.wr_reset_n(mem_reset_n),
  .in_data(gmii_data),.in_en(gmii_en),.in_error(gmii_error),
  .rd_clk(eth_clk),.rd_reset_n(eth_reset_n),.out_data(eth_data),.out_en(eth_en),.out_error(eth_error),
  .wr_fault(bridge_wr_fault),.rd_fault(bridge_rd_fault));
 // Purpose: keep the forwarded reference free-running once the native clock
 // exists. PHY reset and data/control ODDR resets already inhibit reception;
 // an extra fabric-reset path on TXC is unnecessary and complicates its clock
 // propagation. Native GRS still initializes the constant 1/0 forwarding cell.
 pango_rgmii_tx #(.PHY_TXID(1),.SEPARATE_TXC_RESET(1)) u_rgmii(.clk125(eth_tx_clk),.clk125_90(eth_tx_clk),
  .reset_n(eth_tx_reset_n),.txc_reset_n(1'b1),.gmii_data(eth_data),.gmii_en(eth_en),.gmii_error(eth_error),
  .rgmii_txc(rgmii_txc),.rgmii_ctl(rgmii_tx_ctl),.rgmii_data(rgmii_txd));
 // Purpose: report stable status only across domains. HDMI underflow is not
 // hidden by continuing its black raster; the MCU status retains that fact.
 (* syn_preserve=1 *) reg [2:0] sensor_meta,sensor_sync;
 (* syn_preserve=1 *) reg [3:0] led_meta,led_sync;
 reg [24:0] heartbeat;reg [6:0] us_div;reg [63:0] time_us;
 always @(posedge sys_clk or negedge sys_reset_n)
  if(!sys_reset_n)begin heartbeat<=0;led_meta<=0;led_sync<=0;end
  else begin heartbeat<=heartbeat+1'b1;
   led_meta<={core_fault || bridge_fault || phy_fault || sensor_failed,published!=0,link_ready && phy_configured,sensor_ready};
   led_sync<=led_meta;
  end
 assign led={led_sync,heartbeat[24]};
 always @(posedge core_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin sensor_meta<=0;sensor_sync<=0;us_div<=0;time_us<=0;end
  else begin
   sensor_meta<={underflows!=0,sensor_failed,sensor_ready};sensor_sync<=sensor_meta;
   if(us_div==124)begin us_div<=0;time_us<=time_us+1'b1;end else us_div<=us_div+1'b1;
  end
 wire mcu_active;
 // Purpose: preserve status bits0..10 and PHY code16..19; expose individual
 // core faults24..28, writer reason29..31 and bridge faults14/15. No frame,
 // wire format, fault gate or PHY diagnostic command semantics are changed.
 wire [31:0] flags={core_fault_detail,4'b0,phy_fault_code,bridge_wr_fault,bridge_sync,3'b0,sensor_sync[2],published!=0,sensor_sync[0],
                    core_fault || bridge_fault,sensor_sync[1],phy_fault,mcu_active,commissioned,link_ready,phy_configured,1'b1};
 wire [95:0] phy_diagnostics={8'h01,8'h00,phy_status,phy_step,phy_address,phy_last_ack,4'b0,phy_last_read,phy_id};
 // Purpose: this board wires both geometry and frame-atomic view/marker control.
 // Boot writes epoch while commissioned=0 keeps the endpoint in reset, then
 // completes its ACK and guard before entering immutable RUN. commissioned
 // cannot fall, and epoch cannot change, until mem_reset_n resets BOTH blocks.
 // Thus STABLE_LINK_EPOCH removes the impossible live-bus change path, while
 // preserving the first post-reset flush, queue timing and all UART semantics.
 mcu_protocol #(.CLK_HZ(125000000),.BOARD_DIAGNOSTICS(1),.VIDEO_DIAGNOSTICS(1),.CHAIN_DIAGNOSTICS(1),.GEOMETRY_CONTROL(1),.DISPLAY_CONTROL(1),.STABLE_LINK_EPOCH(1)) u_mcu(
  .clk(core_clk),.rst_n(mem_reset_n && commissioned),.uart_rx(uart_rx),.uart_tx(mcu_tx),
  .link_epoch(epoch),.link_epoch_valid(commissioned),.board_time_us(time_us),.status_flags(flags),
  .session_active(mcu_active),.current_session_id(mcu_session_id),.board_diagnostics(phy_diagnostics),
  .geometry_command_valid(geo_cmd_valid),.geometry_command(geo_cmd),.geometry_payload(geo_payload),
  .geometry_code(geo_code),.geometry_reply(geo_reply),
  .video_diagnostics(writer_snapshot),.chain_diagnostics(chain_diagnostics),.env_valid(env_valid),
  .env_session_id(),.env_event_seq(env_seq),.env_mcu_time_us(),.env_board_time_us(env_time),.env_lux_milli(),
  .env_angle_mdeg(env_angle),.env_measurement_valid(env_measurement),.rx_good_count(),.rx_error_count(),.tx_overflow_count());
 // Purpose: copy of the board-proven native controller instantiation from
 // mini_camera_diag/vendor/Top.v; preserve I_ips_ddr_top hierarchy for native FDC.
 // Only new WID/WLAST outputs are connected to validate write acceptance.
ddr3_controller I_ips_ddr_top (
    .ref_clk                   (clk_125Mhz            ),
    .resetn                    (rst_in),// input
    .ddr_init_done             (ddr_init_done      ),// outpu
    .pll_lock                  (pll_lock           ),// outpu
    .core_clk                  (core_clk),                                  // outpu
    .phy_pll_lock              (phy_pll_lock),                          // output
    .gpll_lock                 (gpll_lock),                                // output
    .rst_gpll_lock             (rst_gpll_lock),                        // output
    .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output
    //.ddr_init_done             (ddr_init_done),                        // outpu
    .axi_awaddr                (axi_awaddr         ),// input [27:0]
    .axi_awuser_ap             (1'b0               ),// input
    .axi_awuser_id             (axi_awid           ),// input [3:0]
    .axi_awlen                 (axi_awlen          ),// input [3:0]
    .axi_awready               (axi_awready        ),// output
    .axi_awvalid               (axi_awvalid        ),// input

    .axi_wdata                 (axi_wdata          ),
    .axi_wstrb                 (axi_wstrb          ),// input [31:0]
    .axi_wready                (axi_wready         ),// output
    .axi_wusero_id             (axi_wid            ),// output [3:0]
    .axi_wusero_last           (axi_wlast),// output

    .axi_araddr                (axi_araddr         ),// input [27:0]
    .axi_aruser_ap             (1'b0               ),// input
    .axi_aruser_id             (axi_arid           ),// input [3:0]
    .axi_arlen                 (axi_arlen          ),// input [3:0]
    .axi_arready               (axi_arready        ),// output
    .axi_arvalid               (axi_arvalid        ),// input

    .axi_rdata                 (axi_rdata          ),// output [255:0]
    .axi_rid                   (axi_rid            ),// output [3:0]
    .axi_rlast                 (axi_rlast          ),// output
    .axi_rvalid                (axi_rvalid         ),// outpu

    .apb_clk                   (1'b0               ),// input
    .apb_rst_n                 (1'b1               ),// input
    .apb_sel                   (1'b0               ),// input
    .apb_enable                (1'b0               ),// input
    .apb_addr                  (8'b0               ),// input [7:0]
    .apb_write                 (1'b0               ),// input
    .apb_ready                 (                   ), // output
    .apb_wdata                 (16'b0              ),// input [15:0]
    .apb_rdata                 (                   ),// output [15:0]
//          .apb_int                   (                   ),// outpu
    .mem_rst_n                 (mem_rst_n          ),// output
    .mem_ck                    (mem_ck             ),// output
    .mem_ck_n                  (mem_ck_n           ),// output
    .mem_cke                   (mem_cke            ),// output
    .mem_cs_n                  (mem_cs_n           ),// output
    .mem_ras_n                 (mem_ras_n          ),// output
    .mem_cas_n                 (mem_cas_n          ),// output
    .mem_we_n                  (mem_we_n           ),// output
    .mem_odt                   (mem_odt            ),// output
    .mem_a                     (mem_a              ),// output [14:0]
    .mem_ba                    (mem_ba             ),// output [2:0]
    .mem_dqs                   (mem_dqs            ),// inout [3:0]
    .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
    .mem_dq                    (mem_dq             ),// inout [31:0]
    .mem_dm                    (mem_dm             ),// output [3:0]
    //debug

    .dbg_gate_start(1'b0),                      // input
    .dbg_cpd_start(1'b0),                        // input
    .dbg_ddrphy_rst_n(1'b1),                  // input
    .dbg_gpll_scan_rst(1'b0),                // input
    .samp_position_dyn_adj(1'b0),        // input
    .init_samp_position_even(32'd0),    // input [31:0]
    .init_samp_position_odd(32'd0),      // input [31:0]
    .wrcal_position_dyn_adj(1'b0),      // input
    .init_wrcal_position(32'd0),            // input [31:0]
    .force_read_clk_ctrl(1'b0),            // input
    .init_slip_step(16'd0),                      // input [15:0]
    .init_read_clk_ctrl(12'd0),              // input [11:0]
    .debug_calib_ctrl(),                  // output [33:0]
    .dbg_slice_status(),                  // output [67:0]
    .dbg_slice_state(),                    // output [87:0]
    .debug_data(),                              // output [275:0]
    .dbg_dll_upd_state(),                // output [1:0]
    .debug_gpll_dps_phase(),          // output [8:0]
    .dbg_rst_dps_state(),                // output [2:0]
    .dbg_tran_err_rst_cnt(),          // output [5:0]
    .dbg_ddrphy_init_fail(),          // output
    .debug_cpd_offset_adj(1'b0),          // input
    .debug_cpd_offset_dir(1'b0),          // input
    .debug_cpd_offset(10'd0),                  // input [9:0]
    .debug_dps_cnt_dir0(),              // output [9:0]
    .debug_dps_cnt_dir1(),              // output [9:0]
    .ck_dly_en(1'b0),                                // input
    .init_ck_dly_step(8'h0),                  // input [7:0]
    .ck_dly_set_bin(),                      // output [7:0]
    .align_error(),                            // output
    .debug_rst_state(),                    // output [3:0]
    .debug_cpd_state()                     // output [3:0]
);
endmodule


