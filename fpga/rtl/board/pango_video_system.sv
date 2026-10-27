`timescale 1ns/1ps
// Purpose: MINI video integration candidate: RAW8 S0 -> Ethernet; FPGA ISP S1
// -> affine/lens RGB888 result -> HDMI, with shared native DDR requests.
// PC mode/status/geometry are connected; image egress is RAW only.
// PC-only profile: independent MCU UART is disabled; TX remains idle high.
// PC geometry/reference updates remain frame-atomic through the existing job CDC.
module pango_video_system(
 input clk_27m,ref_clk_p,ref_clk_n,reset_n,output status_led,
 input uart_rx,output uart_tx,
 input mcu_uart_rx,output mcu_uart_tx,
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
 wire processing_raw_clk,processing_clk,processing_lock,processing_reset_n;
 wire video_lock,serial_clk,pixel_clk,pixel_div_clk,hdmi_serial_clk,div_reset_n,video_ref_reset_n,video_ready,video_pixel_reset_n;
 wire camera_control_reset_n;wire core_reset_n,camera_domain_reset_n,pixel_domain_reset_n,ctrl_reset_n,rx_reset_n;
 wire core_fault,camera_ready,camera_failed,camera_lost;
 // Native initialization is independent of processing PLL startup. After
 // arming, controller and all ownership clients share immediate cold reset.
 wire fault_latched,memory_armed,joint_reset_n,fabric_async_reset_n;
 processing_domain_reset processing_safety(.control_clk(clk_27m),.external_reset_n(reset_n),
  .video_lock(video_lock),.processing_lock(processing_lock),.memory_lock(ddr_lock),.memory_ready(ddr_ready),
  .business_fault(core_fault),.camera_lost(camera_lost),.joint_reset_n(joint_reset_n),
  .fabric_async_reset_n(fabric_async_reset_n),.fault_latched(fault_latched),.memory_armed(memory_armed));
 GTP_INBUFDS #(.IOSTANDARD("DEFAULT")) u_ref_input(.I(ref_clk_p),.IB(ref_clk_n),.O(ref_clk));
 // Existing MINI reference is 125MHz (native DDR ref constraint). OUT1
 // is 125*6/5=150MHz; NOBUF output is promoted onto a real global network.
 sys_pll u_processing_pll(.clkin1(ref_clk),.clkout0(),.clkout1(processing_raw_clk),.clkout2(),.lock(processing_lock));
 GTP_CLKBUFG u_processing_global(.CLKIN(processing_raw_clk),.CLKOUT(processing_clk));
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
 reset_sync rs_processing(processing_clk,fabric_async_reset_n,processing_reset_n);
 reset_sync rs_core(ddr_clk,fabric_async_reset_n,core_reset_n);
 // Camera SCCB owner and both request-mailbox ends share cold assertion.
 // Restarting a fabric generation can never consume an old runtime reply.
 reset_sync rs_camera_control(clk_27m,fabric_async_reset_n,camera_control_reset_n);
 reset_sync rs_camera(camera_pclk,fabric_async_reset_n,camera_domain_reset_n);
 reset_sync rs_pixel(pixel_clk,fabric_async_reset_n && video_pixel_reset_n,pixel_domain_reset_n);
 // Fault synchronization and sticky cold-reset arming live in processing_safety.
 dvp_clock_watchdog watchdog(.pclk(camera_pclk),.pclk_reset_n(camera_domain_reset_n),.ctrl_clk(clk_27m),
  .ctrl_reset_n(ctrl_reset_n),.enable(camera_ready),.clock_lost(camera_lost),.loss_event());
 ov5640_integrated_startup camera_init(.clk(clk_27m),.rst_n(camera_control_reset_n),.sensor_reset_n(camera_reset_n),
  .runtime_apply(rt_apply),.runtime_continuous(rt_payload[30]),.runtime_quiesced(quiesced_ctrl),.runtime_exposure(rt_payload[29:10]),.runtime_gain(rt_payload[9:0]),
  .runtime_ready(rt_ready),.runtime_done(rt_done),.runtime_error(rt_error),
  .SCL(camera_scl),.SDA(camera_sda),.ready(camera_ready),.failed(camera_failed),.failure_code(),.active_version(),.active_entity());
 // CP2102 retains PC V1 commissioning and dynamic image/geometry control.
 // MCU automatic pose and kind12 link policy are withdrawn in this profile.
 // Dedicated PC control reaches the frame parameter layer, never the pixel
 // path. Display adoption is observed through an atomic status CDC mailbox.
 // Only connected entity kinds are advertised. Reference remains a distinct
 // frame-bank consumer; image/motion share the single bounded UART upload.
 wire entity_submit_valid;wire [15:0] entity_kind,entity_length,entity_read_kind;
 wire [2047:0] entity_body;wire [7:0] entity_submit_code,image_submit_code,motion_submit_code;
 wire [2303:0] entity_status,image_status,motion_status;
 wire [7:0] camera_submit_code;wire [2303:0] camera_status;
 wire image_auto_stable;wire camera_continuous,camera_pause,source_quiesced,cam_apply,cam_apply_ready,cam_done,cam_failed;
 wire [19:0] cam_exposure;wire [9:0] cam_gain;wire [31:0] camera_config_version;
 wire camera_stats_valid;wire [47:0] camera_stats_sum;wire [31:0] camera_stats_count;
 reg camera_return_valid;reg [2:0] camera_return_error;
 // Capture the held error only after mailbox completion, then deliver an
 // entirely DDR-domain done/error pair to the policy on the following cycle.
 always @(posedge ddr_clk or negedge core_reset_n)begin
  if(!core_reset_n)begin camera_return_valid<=0;camera_return_error<=0;end
  else begin camera_return_valid<=cam_done;if(cam_done)camera_return_error<=cam_failed?rt_error:3'd0;end
 end
 wire rt_apply,rt_ready,rt_done;wire [2:0] rt_error;wire [30:0] rt_payload;
 (* syn_preserve=1 *) reg quiesced_meta,quiesced_ctrl;
 always @(posedge clk_27m or negedge camera_control_reset_n)begin
  if(!camera_control_reset_n)begin quiesced_meta<=0;quiesced_ctrl<=0;end
  else begin quiesced_meta<=source_quiesced;quiesced_ctrl<=quiesced_meta;end
 end
 // Held request mailbox reuses the normal controller drain/ack contract.
 // Returned error bits stay stable until the next request; done is synchronized.
 processing_job_cdc #(.JOB_BITS(31)) camera_apply_bridge(.source_clk(ddr_clk),.source_rst_n(core_reset_n),
  .source_valid(cam_apply),.source_ready(cam_apply_ready),.source_job({camera_continuous,cam_exposure,cam_gain}),.source_done(cam_done),.source_failed(cam_failed),
  .processing_clk(clk_27m),.processing_rst_n(camera_control_reset_n),.processing_valid(rt_apply),.processing_ready(rt_ready),
  .processing_job(rt_payload),.processing_done(rt_done),.processing_failed(rt_error!=0),
  // Camera error already uses the separately constrained held-error return.
  .processing_result(1'b0),.source_result());
 // Manual exposure/gain remains available; automatic image feedback is omitted
 // in the strict-capacity board profile, together with custom tone uploads.
 // Camera timing validation is split across clocks; the upload engine waits
 // for its exact cached result before publishing a command to this consumer.
 camera_brightness_control #(.SUPPORT_AUTO(0),.PIPELINED_VALIDATION(1)) camera_control(.clk(ddr_clk),.rst_n(core_reset_n),
  .submit_valid(entity_submit_valid && entity_kind==7),.body(entity_body[383:0]),.version(reference_version),.entity_id(reference_entity_id),
  .submit_code(camera_submit_code),.status(camera_status),.source_quiesced(source_quiesced),.pause_capture(camera_pause),
  .apply_valid(cam_apply),.continuous(camera_continuous),.apply_ready(cam_apply_ready),.exposure(cam_exposure),.gain(cam_gain),.apply_done(camera_return_valid),.apply_error(camera_return_error),
  .capture_boundary(capture_valid && capture_ready),.capture_epoch(capture_epoch),.capture_frame(capture_id),
  .statistics_valid(camera_stats_valid),.luminance_sum(camera_stats_sum),.samples(camera_stats_count),.capture_camera_version(camera_config_version),.auto_stable(image_auto_stable));
 wire image_kind_selected=entity_kind>=1 && entity_kind<=3;
 wire motion_kind_selected=(entity_kind>=4 && entity_kind<=6) || entity_kind==8;
 wire [7:0] mcu_policy_code;wire [2303:0] mcu_policy_status;
 assign entity_submit_code=entity_kind==12?mcu_policy_code:entity_kind==7?camera_submit_code:image_kind_selected?image_submit_code:motion_kind_selected?motion_submit_code:8'd6;
 assign entity_status=entity_read_kind==12?mcu_policy_status:entity_read_kind==7?camera_status:entity_read_kind<=3?image_status:motion_status;
 wire reference_submit_valid;wire [511:0] reference_entity;wire [31:0] reference_version,reference_entity_id;
 wire [7:0] reference_submit_code;wire [767:0] reference_status;
 wire runtime_action_valid;wire [15:0] runtime_action,runtime_action_seq;wire [7:0] runtime_action_code;
 wire affine_submit_valid;wire [95:0] affine_payload;wire [15:0] affine_sequence;
 wire [7:0] affine_submit_code;wire [767:0] affine_status;
 wire display_confirm_valid,display_confirm_ready;wire [160:0] display_confirm;
 wire [767:0] control_status,geometry_status;wire geometry_submit_valid,geometry_submit_ready;wire [543:0] geometry_submit;wire [31:0] geometry_version,geometry_entity_id;wire mode_submit_valid,mode_submit_ready;wire [1:0] mode_submit;wire [31:0] mode_version;
 wire commissioned;wire [63:0] boot_epoch;wire [47:0] local_mac,peer_mac;
 wire [31:0] local_ip,peer_ip;wire [15:0] local_port,peer_port;
 // C4 kind4 and the inactive kind6 completion/history API are not advertised.
 // No custom LUT, viewport, MCU pose/policy, motion diagnostics or disabled
 // completion configuration. PC image/geometry/reference controls remain.
 // Gateway storage and status capacity follow the same board feature mask.
 // The sole kind3 ingress proves coefficient rows during CRC upload. Pair
 // STREAM_CCM with the core specialization; no alternate unproved ingress.
 pc_video_boot #(.ENTITY_MASK(16'h028a),.STREAM_CCM(1),.SUMMARY_READBACK(1)) boot(.clk(ddr_clk),.rst_n(core_reset_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
  .entity_submit_valid(entity_submit_valid),.entity_kind(entity_kind),.entity_length(entity_length),
  .entity_body(entity_body),.entity_submit_code(entity_submit_code),.entity_read_kind(entity_read_kind),.entity_status(entity_status),
  .configured(commissioned),.epoch(boot_epoch),.local_mac(local_mac),.peer_mac(peer_mac),
  .local_ip(local_ip),.peer_ip(peer_ip),.local_port(local_port),.peer_port(peer_port),
  .geometry_status(geometry_status),.geometry_submit_valid(geometry_submit_valid),.geometry_submit_ready(geometry_submit_ready),.geometry_submit(geometry_submit),.geometry_version(geometry_version),.geometry_entity_id(geometry_entity_id),
  .reference_status(reference_status),.reference_submit_valid(reference_submit_valid),.reference_entity(reference_entity),.reference_version(reference_version),.reference_entity_id(reference_entity_id),.reference_submit_code(reference_submit_code),
  .runtime_action_valid(runtime_action_valid),.runtime_action(runtime_action),.runtime_action_seq(runtime_action_seq),.runtime_action_code(runtime_action_code),
  .affine_status(affine_status),.affine_submit_valid(affine_submit_valid),.affine_payload(affine_payload),.affine_sequence(affine_sequence),.affine_submit_code(affine_submit_code),
  .control_status(control_status),.mode_submit_valid(mode_submit_valid),.mode_submit_ready(mode_submit_ready),.mode_submit(mode_submit),.mode_version(mode_version));
 // Legacy core ports are retained for other module profiles. This board
 // supplies inactive constants and instantiates no MCU adapter.
 wire mcu_enable,mcu_rx_valid,mcu_rx_error,mcu_tx_valid,mcu_tx_ready,mcu_timing_valid;
 wire [7:0] mcu_rx_data,mcu_tx_data;wire [31:0] mcu_new_session,mcu_capture_error,mcu_config_version;
 wire mcu_config_valid,mcu_config_ready,mcu_config_approved,mcu_reopen_required;
 wire [31:0] mcu_config_crc32;
 wire [2111:0] mcu_config_entity;wire mcu_event_valid,mcu_event_ready;wire [319:0] mcu_event_payload;
 wire mcu_session_valid,mcu_mapping_valid;wire [63:0] mcu_boot_id;
 // No MCU protocol/session/pose hardware in this board profile. Keep the
 // physical pins stable for the existing PCF; RX is unused and TX is idle.
 assign mcu_uart_tx=1'b1,mcu_policy_code=8'd6,mcu_policy_status=0;
 assign mcu_enable=0,mcu_rx_valid=0,mcu_rx_error=0,mcu_rx_data=0,mcu_tx_ready=0;
 assign mcu_timing_valid=0,mcu_new_session=0,mcu_capture_error=0;
 assign mcu_config_ready=0,mcu_config_approved=0,mcu_event_ready=0;
 wire capture_valid,capture_ready,capture_complete,capture_end,isp_legal,raw_legal,isp_abort,raw_abort,queues_drained;
 wire [63:0] capture_epoch,capture_id,capture_first,capture_last;
 wire [31:0] capture_errors;wire isp_valid,isp_ready,raw_valid,raw_ready;wire [7:0] isp_byte,raw_byte;
 camera_frame_cdc camera_input(.pclk(camera_pclk),.pclk_rst_n(camera_domain_reset_n),.dvp_data(camera_data),
  .href(camera_href),.vsync(camera_vsync),.camera_ready(camera_ready && commissioned && !camera_pause),.boot_epoch(boot_epoch),
  .memory_clk(ddr_clk),.memory_rst_n(core_reset_n),
  .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_complete(capture_complete),
  .epoch(capture_epoch),.frame_id(capture_id),.capture_first(capture_first),.capture_last(capture_last),
  .capture_end(capture_end),.isp_legal(isp_legal),.raw_legal(raw_legal),.capture_errors(capture_errors),.isp_abort(isp_abort),.raw_abort(raw_abort),
  .isp_valid(isp_valid),.isp_ready(isp_ready),.isp_data(isp_byte),.raw_valid(raw_valid),.raw_ready(raw_ready),.raw_data(raw_byte),
  .queues_drained(queues_drained),.source_quiesced(source_quiesced),.source_frames(),.dropped_raw(),.dropped_isp());
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
 // tag_valid/epoch/id/generation originate from the adopted HDMI descriptor.
 // The mailbox freezes all identity bits together; no independently sampled
 // counters or asynchronous UART arrival ordering can establish association.
 counter_snapshot_cdc #(.BITS(161)) displayed_status_cdc(
  .src_clk(pixel_clk),.src_rst_n(pixel_domain_reset_n),
  .counters({tag_valid,display_epoch,display_id,display_generation}),
  .dst_clk(ddr_clk),.dst_rst_n(core_reset_n),.request(display_confirm_ready),
  .request_ready(display_confirm_ready),.snapshot_valid(display_confirm_valid),
  .snapshot_ready(1'b1),.snapshot(display_confirm));
 wire [31:0] captured,dropped,processed,failed_processing;
 // Existing calibration report supplies these coefficients. Its source stage
 // remains unverified; optical accuracy is not established by offline routing.
 localparam [447:0] CANDIDATE_COEFFICIENTS=448'h0246436103b36be2034ed96d03543ce2ffffbdfcfffe80d80030a9bffefcff55fd3fef320001358d00000000fb8da2030000000000013398;
 // Version-1 fixed OFF view: unrotated output rays, Q26, from the existing
 // baseline output intrinsics (not recovered from a user-submitted ON matrix).
 // This is a reproducible engineering seed, not a newly certified calibration.
 localparam [511:0] AFFINE_REFERENCE_V1={112'd0,16'd1,32'd1,16'd1080,16'd1920,
  -32'sd46141646,32'sd79245,32'sd0,-32'sd74604029,32'sd0,32'sd78744,
  32'd38159366,32'd62090440,32'd55499357,32'd55852465};
 // All image COMMIT pulses here originate in pc_reference_upload, which
 // validates every LUT byte alongside CRC before raising submit_valid. There
 // is no alternate LUT writer; standalone core defaults keep full validation.
 // The physical consumer uses an all-byte configuration digest; keep the
 // full parallel entity mode available to direct-core reference consumers.
 video_memory_core #(.STATIC_ENDPOINTS(0),.SUPPORT_CONTROLS(1),.TONE_LUT_PREVALIDATED(1),.MCU_CONFIG_DIGEST_ONLY(1),.PC_ONLY_CONTROL(1),.CCM_PREVALIDATED(1),.IMAGE_AUTOMATION(0),.TONE_UPLOAD(0),.SUPPORT_VIEWPORT(0)) core(.clk(ddr_clk),.rst_n(core_reset_n),.processing_clk(processing_clk),.processing_rst_n(processing_reset_n),.controller_ready(ddr_ready),.geometry_coefficients(CANDIDATE_COEFFICIENTS),.enhancement(2'd0),
  .image_submit_valid(entity_submit_valid && image_kind_selected),.image_kind(entity_kind),
  .image_entity(entity_body),.image_version(reference_version),.image_id(reference_entity_id),
  .image_submit_code(image_submit_code),.image_read_kind(entity_read_kind),.image_status(image_status),
  .camera_config_version(camera_config_version),.image_auto_stable(image_auto_stable),.camera_stats_valid(camera_stats_valid),.camera_stats_sum(camera_stats_sum),.camera_stats_count(camera_stats_count),
  .motion_submit_valid(entity_submit_valid && motion_kind_selected),.motion_kind(entity_kind),
  .motion_entity(entity_body[1023:0]),.motion_version(reference_version),.motion_id(reference_entity_id),
  .motion_submit_code(motion_submit_code),.motion_read_kind(entity_read_kind),.motion_status(motion_status),
  // Legacy compatibility ports are tied off; PC_ONLY_CONTROL removes
  // the MCU receiver, time mapper, selector and pose model from this netlist.
  .mcu_enable(mcu_enable),.mcu_rx_valid(mcu_rx_valid),.mcu_rx_data(mcu_rx_data),.mcu_rx_error(mcu_rx_error),
  .mcu_tx_valid(mcu_tx_valid),.mcu_tx_data(mcu_tx_data),.mcu_tx_ready(mcu_tx_ready),.mcu_timing_valid(mcu_timing_valid),
  .mcu_capture_error(mcu_capture_error),.mcu_config_approved(mcu_config_approved),
  .mcu_new_session(mcu_new_session),.mcu_config_valid(mcu_config_valid),.mcu_config_entity(mcu_config_entity),.mcu_config_version(mcu_config_version),
  .mcu_config_ready(mcu_config_ready),.mcu_config_crc32(mcu_config_crc32),.mcu_reopen_required(mcu_reopen_required),.mcu_event_valid(mcu_event_valid),.mcu_event_payload(mcu_event_payload),.mcu_event_ready(mcu_event_ready),
  .mcu_session_valid(mcu_session_valid),.mcu_mapping_valid(mcu_mapping_valid),.mcu_boot_id(mcu_boot_id),
  .affine_reference(AFFINE_REFERENCE_V1),
  .display_confirm_valid(display_confirm_valid && display_confirm[160]),
  .display_confirm_epoch(display_confirm[159:96]),.display_confirm_frame(display_confirm[95:32]),
  .display_confirm_generation(display_confirm[31:0]),
  .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_complete(capture_complete),
  .geometry_status(geometry_status),.geometry_submit_valid(geometry_submit_valid),.geometry_submit_ready(geometry_submit_ready),.geometry_submit(geometry_submit),.geometry_version(geometry_version),.geometry_entity_id(geometry_entity_id),
  .reference_status(reference_status),.reference_submit_valid(reference_submit_valid),.reference_entity(reference_entity),.reference_version(reference_version),.reference_entity_id(reference_entity_id),.reference_submit_code(reference_submit_code),
  .runtime_action_valid(runtime_action_valid),.runtime_action(runtime_action),.runtime_action_seq(runtime_action_seq),.runtime_action_code(runtime_action_code),
  .affine_status(affine_status),.affine_submit_valid(affine_submit_valid),.affine_payload(affine_payload),.affine_sequence(affine_sequence),.affine_submit_code(affine_submit_code),
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
