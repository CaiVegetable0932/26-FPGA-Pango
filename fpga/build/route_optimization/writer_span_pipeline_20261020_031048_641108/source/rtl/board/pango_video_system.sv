`timescale 1ns/1ps
// Purpose: MINI video integration candidate: RAW8 S0 -> Ethernet; FPGA ISP S1
// -> projective/lens RGB888 result -> HDMI, with shared native DDR requests.
// PC mode/status/geometry and same-source paired snapshots are connected.
// Calibrated MCU motion remains unavailable without its physical/extrinsic inputs. This engineering candidate is not a full-function release.
module pango_video_system(
 input clk_27m,ref_clk_p,ref_clk_n,reset_n,output status_led,
 input uart_rx,output uart_tx,
 input camera_pclk,camera_href,camera_vsync,input [7:0] camera_data,
 inout camera_scl,camera_sda,output camera_reset_n,
 input rgmii_rxc,rgmii_rx_ctl,input [3:0] rgmii_rxd,
 output rgmii_txc,rgmii_tx_ctl,output [3:0] rgmii_txd,
 output phy_reset_n,phy_mdc,inout phy_mdio,
 output hdmi_clk_p,hdmi_clk_n,output [2:0] hdmi_data_p,hdmi_data_n,
 output mem_cs_n,mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_ras_n,mem_cas_n,mem_we_n,mem_odt,
 output [14:0] mem_a,output [2:0] mem_ba,inout [3:0] mem_dqs,mem_dqs_n,
 inout [31:0] mem_dq,output [3:0] mem_dm
);
 wire ref_clk,ddr_clk,ddr_lock,ddr_ready;
 wire video_lock,serial_clk,pixel_clk,pixel_div_clk,hdmi_serial_clk,div_reset_n,video_ref_reset_n,video_ready,video_pixel_reset_n;
 wire core_reset_n,camera_domain_reset_n,pixel_domain_reset_n,ctrl_reset_n,rx_reset_n;
 wire core_fault,camera_ready,camera_failed,camera_lost;
 reg fault_latched,memory_armed;
 (* syn_preserve=1 *) reg memory_ready_meta,memory_ready_sync;
 // After the first successful initialization, loss of DDR ready/lock asserts
 // the SAME cold reset at controller and clients immediately. A latched fault
 // then prevents an automatic restart from accepting old responses/toggles.
 wire joint_reset_n=reset_n && video_lock && !fault_latched &&
  (!memory_armed || (ddr_ready && ddr_lock));
 GTP_INBUFDS #(.IOSTANDARD("DEFAULT")) u_ref_input(.I(ref_clk_p),.IB(ref_clk_n),.O(ref_clk));
 video_pll u_video_pll(.clkin1(clk_27m),.clkout1(serial_clk),.lock(video_lock));
 GTP_IOCLKBUF u_hdmi_serial_clock(.CLKIN(serial_clk),.DI(1'b1),.CLKOUT(hdmi_serial_clk));
 GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_hdmi_pixel_div(.CLKIN(serial_clk),.RST_N(div_reset_n),.CE(1'b1),.CLKDIVOUT(pixel_div_clk));
 // Logos2 DS04001 distinguishes regional clock coverage from global coverage.
 // The full two-line scanout/CDC RAM exceeded the divider's regional loaders
 // in native PnR (Place-0089). Keep its serializers regional and promote the
 // same divided source through native CLKBUFG for pixel RAM/encoding logic.
 // This candidate connection must pass native place/route and related-clock
 // min/max STA; it is not inferred from another FPGA family's clock rules.
 GTP_CLKBUFG u_pixel_global(.CLKIN(pixel_div_clk),.CLKOUT(pixel_clk));
 video_clock_start u_video_start(.ref_clk(clk_27m),.pixel_clk(pixel_clk),.async_reset_n(reset_n && video_lock),
  .reference_reset_n(video_ref_reset_n),.divider_reset_n(div_reset_n),.clock_ready(video_ready),.pixel_reset_n(video_pixel_reset_n));
 reset_sync rs_ctrl(clk_27m,reset_n,ctrl_reset_n);
 // All ownership/storage CDC clients share the controller cold-reset request.
 // Native fault or stopped PCLK quarantines them until a board reset.
 wire fabric_async_reset_n=joint_reset_n && ddr_lock && ddr_ready;
 reset_sync rs_core(ddr_clk,fabric_async_reset_n,core_reset_n);
 reset_sync rs_camera(camera_pclk,fabric_async_reset_n,camera_domain_reset_n);
 reset_sync rs_pixel(pixel_clk,fabric_async_reset_n && video_pixel_reset_n,pixel_domain_reset_n);
 (* syn_preserve=1 *) reg fault_meta,fault_sync;
 always @(posedge clk_27m or negedge ctrl_reset_n)begin
  if(!ctrl_reset_n)begin fault_meta<=0;fault_sync<=0;fault_latched<=0;memory_armed<=0;memory_ready_meta<=0;memory_ready_sync<=0;end
  else begin
   fault_meta<=core_fault;fault_sync<=fault_meta;memory_ready_meta<=ddr_ready && ddr_lock;memory_ready_sync<=memory_ready_meta;
   if(memory_ready_sync)memory_armed<=1;
   if(fault_sync || camera_lost || (memory_armed && !memory_ready_sync))fault_latched<=1;
  end
 end
 dvp_clock_watchdog watchdog(.pclk(camera_pclk),.pclk_reset_n(camera_domain_reset_n),.ctrl_clk(clk_27m),
  .ctrl_reset_n(ctrl_reset_n),.enable(camera_ready),.clock_lost(camera_lost),.loss_event());
 ov5640_integrated_startup camera_init(.clk(clk_27m),.rst_n(ctrl_reset_n),.sensor_reset_n(camera_reset_n),
  .SCL(camera_scl),.SDA(camera_sda),.ready(camera_ready),.failed(camera_failed),.failure_code(),.active_version(),.active_entity());
 // CP2102 boot uses the existing PC V1 RAW8 commissioning entity. MCU V2
 // remains a separate independent interface, outside this cabling revision.
 wire snapshot_arm,snapshot_arm_ready;wire [767:0] control_status,geometry_status,snapshot_s1_status,snapshot_result_status,snapshot_geometry_status;wire geometry_submit_valid,geometry_submit_ready;wire [543:0] geometry_submit;wire [31:0] geometry_version,geometry_entity_id;wire mode_submit_valid,mode_submit_ready;wire [1:0] mode_submit;wire [31:0] mode_version;
 wire commissioned;wire [63:0] boot_epoch;wire [47:0] local_mac,peer_mac;
 wire [31:0] local_ip,peer_ip;wire [15:0] local_port,peer_port;
 pc_video_boot boot(.clk(ddr_clk),.rst_n(core_reset_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
  .configured(commissioned),.epoch(boot_epoch),.local_mac(local_mac),.peer_mac(peer_mac),
  .local_ip(local_ip),.peer_ip(peer_ip),.local_port(local_port),.peer_port(peer_port),
  .snapshot_arm(snapshot_arm),.snapshot_arm_ready(snapshot_arm_ready),.snapshot_geometry_status(snapshot_geometry_status),.snapshot_s1_status(snapshot_s1_status),.snapshot_result_status(snapshot_result_status),.geometry_status(geometry_status),.geometry_submit_valid(geometry_submit_valid),.geometry_submit_ready(geometry_submit_ready),.geometry_submit(geometry_submit),.geometry_version(geometry_version),.geometry_entity_id(geometry_entity_id),
  .control_status(control_status),.mode_submit_valid(mode_submit_valid),.mode_submit_ready(mode_submit_ready),.mode_submit(mode_submit),.mode_version(mode_version));
 wire capture_valid,capture_ready,capture_complete,capture_end,isp_legal,raw_legal,isp_abort,raw_abort,queues_drained;
 wire [63:0] capture_epoch,capture_id,capture_first,capture_last;
 wire [31:0] capture_errors;wire isp_valid,isp_ready,raw_valid,raw_ready;wire [7:0] isp_byte,raw_byte;
 camera_frame_cdc camera_input(.pclk(camera_pclk),.pclk_rst_n(camera_domain_reset_n),.dvp_data(camera_data),
  .href(camera_href),.vsync(camera_vsync),.camera_ready(camera_ready && commissioned),.boot_epoch(boot_epoch),
  .memory_clk(ddr_clk),.memory_rst_n(core_reset_n),.capture_valid(capture_valid),.capture_ready(capture_ready),.capture_complete(capture_complete),
  .epoch(capture_epoch),.frame_id(capture_id),.capture_first(capture_first),.capture_last(capture_last),
  .capture_end(capture_end),.isp_legal(isp_legal),.raw_legal(raw_legal),.capture_errors(capture_errors),.isp_abort(isp_abort),.raw_abort(raw_abort),
  .isp_valid(isp_valid),.isp_ready(isp_ready),.isp_data(isp_byte),.raw_valid(raw_valid),.raw_ready(raw_ready),.raw_data(raw_byte),
  .queues_drained(queues_drained),.source_frames(),.dropped_raw(),.dropped_isp());
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,awid,arid,wid,rid;
 wire awvalid,arvalid,awready,arready,wready,wlast,rlast,ddr_rvalid;
 wire [255:0] ddr_rdata,ddr_wdata;wire [31:0] wstrb;
 // The native controller instance name binds the copied official constraints.
 // Its concrete PHY/APB/board ports are populated from the existing main top.
     ddr3_controller I_ips_ddr_top(
        .ref_clk(ref_clk), .resetn(joint_reset_n), .core_clk(ddr_clk), .pll_lock(ddr_lock),
        .phy_pll_lock(), .gpll_lock(), .rst_gpll_lock(), .ddrphy_cpd_lock(), .ddr_init_done(ddr_ready),
        .axi_awaddr(awaddr), .axi_awuser_ap(1'b0), .axi_awuser_id(awid),
        .axi_awlen(awlen), .axi_awready(awready), .axi_awvalid(awvalid),
        .axi_wdata(ddr_wdata), .axi_wstrb(wstrb), .axi_wready(wready), .axi_wusero_id(wid), .axi_wusero_last(wlast),
        .axi_araddr(araddr), .axi_aruser_ap(1'b0), .axi_aruser_id(arid),
        .axi_arlen(arlen), .axi_arready(arready), .axi_arvalid(arvalid),
        .axi_rdata(ddr_rdata), .axi_rid(rid), .axi_rlast(rlast), .axi_rvalid(ddr_rvalid),
        .apb_clk(clk_27m), .apb_rst_n(ctrl_reset_n), .apb_sel(1'b0), .apb_enable(1'b0),
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

 // MAC TX shares the true DDR 125 MHz domain. RX crosses whole completed
 // wire frames, so neither independent oscillator drift nor FIFO empty inserts
 // a gap inside a frame. Unshifted TXC uses verified PHY internal TX delay.
 wire rx_clk,rx_dv,rx_er;wire [7:0] rx_data,mac_rx_data,tx_data;wire mac_rx_valid,mac_rx_error,tx_en,tx_er;
 rgmii_phy_io phy_io(.tx_clk(ddr_clk),.reset(!fabric_async_reset_n),.tx_data(tx_data),.tx_valid(tx_en),
  .rgmii_rxc(rgmii_rxc),.rgmii_rxd(rgmii_rxd),.rgmii_rx_ctl(rgmii_rx_ctl),.rx_clk(rx_clk),.rx_data(rx_data),.rx_valid(rx_dv),.rx_error(rx_er),
  .rgmii_txc(rgmii_txc),.rgmii_txd(rgmii_txd),.rgmii_tx_ctl(rgmii_tx_ctl));
 reset_sync rs_rx(rx_clk,fabric_async_reset_n,rx_reset_n);
 gmii_receive_cdc rx_bridge(.rx_clk(rx_clk),.rx_rst_n(rx_reset_n),.rx_data(rx_data),.rx_dv(rx_dv),.rx_er(rx_er),
  .memory_clk(ddr_clk),.memory_rst_n(core_reset_n),.data(mac_rx_data),.valid(mac_rx_valid),.error(mac_rx_error),.dropped_frames());
 wire mdio_o,mdio_oe,link_ready;
 assign phy_mdio=mdio_oe ? mdio_o : 1'bz;
 mini_phy_startup #(.PHY_TX_DELAY(1),.SCAN_ADDRESSES(1)) phy_init(.clk(ddr_clk),.reset_n(core_reset_n),.mdio_i(phy_mdio),
  .mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(phy_mdc),.phy_reset_n(phy_reset_n),.configured(),.link_ready(link_ready),
  .fault(),.fault_code(),.phy_status(),.phy_id(),.selected_addr(),.diagnostic_step(),.last_read(),.last_ack_error());
 wire display_request,m_offer,m_offer_ready,m_release,m_release_ready;
 wire [31:0] m_base,m_gen,m_release_gen;wire [1:0] m_slot,m_release_slot;wire [63:0] m_epoch,m_id;
 wire p_offer,p_offer_ready,p_release,p_release_ready;
 wire [31:0] p_base,p_gen,p_release_gen;wire [1:0] p_slot,p_release_slot;wire [63:0] p_epoch,p_id;
 display_frame_cdc display_context(.memory_clk(ddr_clk),.memory_rst_n(core_reset_n),.memory_request(display_request),
  .memory_offer_valid(m_offer),.memory_offer_ready(m_offer_ready),.memory_base(m_base),.memory_generation(m_gen),.memory_slot(m_slot),
  .memory_epoch(m_epoch),.memory_id(m_id),.memory_release_valid(m_release),.memory_release_ready(m_release_ready),
  .memory_release_slot(m_release_slot),.memory_release_generation(m_release_gen),.pixel_clk(pixel_clk),.pixel_rst_n(pixel_domain_reset_n),
  .pixel_offer_valid(p_offer),.pixel_offer_ready(p_offer_ready),.pixel_base(p_base),.pixel_generation(p_gen),.pixel_slot(p_slot),.pixel_epoch(p_epoch),.pixel_id(p_id),
  .pixel_release_valid(p_release),.pixel_release_ready(p_release_ready),.pixel_release_slot(p_release_slot),.pixel_release_generation(p_release_gen));
 wire p_req,p_req_ready,p_cancel,p_rvalid,p_rready,p_rlast,p_done,p_done_ready,p_error,p_cancelled,p_urgent;
 wire [31:0] p_addr,p_tag,p_done_tag;wire [4:0] p_beats;wire [255:0] p_rdata;
 wire m_req,m_req_ready,m_cancel,m_rvalid,m_rready,m_rlast,m_done,m_done_ready,m_error,m_cancelled;
 wire [31:0] m_addr,m_tag,m_done_tag;wire [4:0] m_beats;wire [255:0] m_rdata;
 (* syn_preserve=1 *) reg urgent_meta,urgent_sync;
 always @(posedge ddr_clk or negedge core_reset_n)if(!core_reset_n)begin urgent_meta<=0;urgent_sync<=0;end
  else begin urgent_meta<=p_urgent;urgent_sync<=urgent_meta;end
 dma_read_cdc display_dma(.client_clk(pixel_clk),.client_rst_n(pixel_domain_reset_n),.req_valid(p_req),.req_ready(p_req_ready),
  .req_addr(p_addr),.req_tag(p_tag),.req_beats(p_beats),.cancel(p_cancel),.r_valid(p_rvalid),.r_ready(p_rready),.r_data(p_rdata),.r_last(p_rlast),
  .done(p_done),.done_ready(p_done_ready),.error(p_error),.cancelled(p_cancelled),.done_tag(p_done_tag),.memory_clk(ddr_clk),.memory_rst_n(core_reset_n),
  .memory_req_valid(m_req),.memory_req_ready(m_req_ready),.memory_req_addr(m_addr),.memory_req_tag(m_tag),.memory_req_beats(m_beats),.memory_cancel(m_cancel),
  .memory_r_valid(m_rvalid),.memory_r_ready(m_rready),.memory_r_data(m_rdata),.memory_r_last(m_rlast),
  .memory_done(m_done),.memory_done_ready(m_done_ready),.memory_error(m_error),.memory_cancelled(m_cancelled),.memory_done_tag(m_done_tag));
 wire hs,vs,de,tag_valid;wire [23:0] rgb;wire [63:0] display_epoch,display_id;wire [31:0] display_generation;
 hdmi_display display(.clk(pixel_clk),.rst_n(pixel_domain_reset_n),.stream_enable(1'b1),.locked(1'b1),
  .offer_valid(p_offer),.offer_ready(p_offer_ready),.offer_base(p_base),.offer_generation(p_gen),.offer_slot(p_slot),.offer_epoch(p_epoch),.offer_frame_id(p_id),
  .release_valid(p_release),.release_ready(p_release_ready),.release_slot(p_release_slot),.release_generation(p_release_gen),
  .frame_boundary(),.hs(hs),.vs(vs),.de(de),.rgb(rgb),.x(),.y(),.tag_valid(tag_valid),.epoch(display_epoch),.source_frame_id(display_id),.generation(display_generation),
  .display_new_frames(),.display_repeat_frames(),.display_failed_frames(),.display_scan_frames(),.display_empty_frames(),
  .underflow_events(),.underflow_pixels(),.max_no_service_cycles(),.low_water_cycles(),
  .req_valid(p_req),.req_ready(p_req_ready),.req_addr(p_addr),.req_beats(p_beats),.req_tag(p_tag),.r_valid(p_rvalid),.r_ready(p_rready),.r_data(p_rdata),.r_last(p_rlast),
  .done(p_done),.done_ready(p_done_ready),.cancelled(p_cancelled),.error(p_error),.done_tag(p_done_tag),.cancel(p_cancel),.urgent(p_urgent),.ready_lines(),.dma_fault());
 hdmi_rgb888_tx #(.SPLIT_PIXEL_CLOCKS(1)) hdmi(.pixel_clk(pixel_clk),.serializer_pixel_clk(pixel_div_clk),.serial_clk(hdmi_serial_clk),.pixel_rst_n(pixel_domain_reset_n),.serializer_reset(!div_reset_n),
  .rgb(rgb),.hs(hs),.vs(vs),.de(de),.tag_valid(tag_valid),.epoch(display_epoch),.source_frame_id(display_id),.generation(display_generation),
  .data_p(hdmi_data_p),.data_n(hdmi_data_n),.clock_p(hdmi_clk_p),.clock_n(hdmi_clk_n),
  .symbol_tag_valid(),.symbol_epoch(),.symbol_source_frame_id(),.symbol_generation());
 wire [31:0] captured,dropped,processed,failed_processing;
 // Existing calibration report supplies these coefficients. Its source stage
 // remains unverified; optical accuracy is not established by offline routing.
 localparam [447:0] CANDIDATE_COEFFICIENTS=448'h0246436103b36be2034ed96d03543ce2ffffbdfcfffe80d80030a9bffefcff55fd3fef320001358d00000000fb8da2030000000000013398;
 video_memory_core #(.STATIC_ENDPOINTS(0),.SUPPORT_CONTROLS(1),.SUPPORT_SNAPSHOT(1)) core(.clk(ddr_clk),.rst_n(core_reset_n),.controller_ready(ddr_ready),.geometry_coefficients(CANDIDATE_COEFFICIENTS),.enhancement(2'd0),
  .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_complete(capture_complete),
  .snapshot_arm(snapshot_arm),.snapshot_arm_ready(snapshot_arm_ready),.snapshot_geometry_status(snapshot_geometry_status),.snapshot_s1_status(snapshot_s1_status),.snapshot_result_status(snapshot_result_status),.geometry_status(geometry_status),.geometry_submit_valid(geometry_submit_valid),.geometry_submit_ready(geometry_submit_ready),.geometry_submit(geometry_submit),.geometry_version(geometry_version),.geometry_entity_id(geometry_entity_id),
  .control_status(control_status),.mode_submit_valid(mode_submit_valid),.mode_submit_ready(mode_submit_ready),.mode_submit(mode_submit),.mode_version(mode_version),
  .capture_epoch(capture_epoch),.capture_id(capture_id),.capture_first(capture_first),.capture_last(capture_last),
  .capture_end(capture_end),.capture_isp_legal(isp_legal),.capture_raw_legal(raw_legal),.capture_errors(capture_errors),
  .isp_abort(isp_abort),.raw_abort(raw_abort),.capture_queues_drained(queues_drained),
  .isp_byte_valid(isp_valid),.isp_byte_ready(isp_ready),.isp_byte(isp_byte),.raw_byte_valid(raw_valid),.raw_byte_ready(raw_ready),.raw_byte(raw_byte),
  .display_request(display_request),.display_offer_valid(m_offer),.display_offer_ready(m_offer_ready),.display_base(m_base),.display_gen(m_gen),.display_slot(m_slot),
  .display_epoch(m_epoch),.display_id(m_id),.display_release(m_release),.display_release_slot(m_release_slot),.display_release_gen(m_release_gen),.display_release_ready(m_release_ready),
  .display_req_valid(m_req),.display_req_ready(m_req_ready),.display_req_addr(m_addr),.display_req_tag(m_tag),.display_req_beats(m_beats),.display_cancel(m_cancel),.display_urgent(urgent_sync),
  .display_r_valid(m_rvalid),.display_r_ready(m_rready),.display_r_data(m_rdata),.display_r_last(m_rlast),.display_done(m_done),.display_done_ready(m_done_ready),
  .display_error(m_error),.display_cancelled(m_cancelled),.display_done_tag(m_done_tag),
  .rx_data(mac_rx_data),.rx_dv(mac_rx_valid),.rx_er(mac_rx_error),.gigabit_link(link_ready && commissioned),
  .network_local_mac(local_mac),.network_peer_mac(peer_mac),.network_local_ip(local_ip),.network_peer_ip(peer_ip),.network_local_port(local_port),.network_peer_port(peer_port),.tx_data(tx_data),.tx_en(tx_en),.tx_er(tx_er),.fault(core_fault),
  .captured_frames(captured),.dropped_capture_frames(dropped),.processed_frames(processed),.failed_processing_frames(failed_processing),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.awid(awid),.arid(arid),.awvalid(awvalid),.arvalid(arvalid),.awready(awready),.arready(arready),
  .native_wdata(ddr_wdata),.native_wstrb(wstrb),.native_wready(wready),.native_wlast(wlast),.native_wid(wid),
  .native_rdata(ddr_rdata),.native_rvalid(ddr_rvalid),.native_rlast(rlast),.native_rid(rid));
 // Activity/fault indication only; an LED is not a throughput/acceptance test.
 (* syn_preserve=1 *) reg activity_meta,activity_sync;
 always @(posedge clk_27m or negedge ctrl_reset_n)if(!ctrl_reset_n)begin activity_meta<=0;activity_sync<=0;end
  else begin activity_meta<=processed[4];activity_sync<=activity_meta;end
 assign status_led=fault_latched || camera_failed || activity_sync;
endmodule
