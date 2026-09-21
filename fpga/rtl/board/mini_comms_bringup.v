// Purpose: isolated PG2L100H MINI communication commissioning image.
// NO CAMERA, DDR, ISP OR HDMI pipeline is instantiated here. CP2102 acts as an
// MCU emulator port until actual MCU wiring is confirmed; no free header pin
// is driven. Network stays silent until explicit boot configuration and a
// verified 1000/full PHY link. This candidate does not replace camera baseline.
module mini_comms_bringup(
 input wire ref_clk_p,ref_clk_n,reset_n,uart_rx,output wire uart_tx,
 output wire phy_reset_n,phy_mdc,inout wire phy_mdio,
 output wire rgmii_txc,rgmii_tx_ctl,output wire [3:0] rgmii_txd,
 output wire [4:0] led
);
 wire reference_clk,clk125,locked,rst125;
 GTP_INBUFDS u_ref(.I(ref_clk_p),.IB(ref_clk_n),.O(reference_clk));
 comms_pll u_pll(.clkin1(reference_clk),.rst(~reset_n),.clkout0(clk125),.clkout1(),.lock(locked));
 reset_sync u_reset125(.clk(clk125),.async_reset_n(reset_n && locked),.reset_n(rst125));
 // Purpose: TX clock and all DDR data cells share ONE physical clock tree.
 // The PHY supplies the 2 ns receive sampling delay; this avoids independent
 // FPGA clock-tree variation. Do not also connect the available +90 PLL output.
 wire mdio_o,mdio_oe,phy_configured,link_ready,phy_fault;
 wire [3:0] phy_fault_code;wire [15:0] phy_status;wire [31:0] phy_id;
 assign phy_mdio=mdio_oe?mdio_o:1'bz;
 rtl8211f_init #(.PHY_TX_DELAY(1)) u_phy(.clk(clk125),.reset_n(rst125),.mdio_i(phy_mdio),
  .mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(phy_mdc),.phy_reset_n(phy_reset_n),
  .configured(phy_configured),.link_ready(link_ready),.fault(phy_fault),
  .fault_code(phy_fault_code),.phy_status(phy_status),.phy_id(phy_id));
 wire commissioned,mcu_tx;wire [63:0] epoch;wire [47:0] src_mac,dst_mac;
 wire [31:0] src_ip,dst_ip;wire [15:0] src_port,dst_port;
 comms_boot_config u_boot(.clk(clk125),.reset_n(rst125),.uart_rx(uart_rx),
  .mcu_tx(mcu_tx),.uart_tx(uart_tx),.configured(commissioned),.epoch(epoch),
  .src_mac(src_mac),.dst_mac(dst_mac),.src_ip(src_ip),.dst_ip(dst_ip),
  .src_port(src_port),.dst_port(dst_port));
 wire frame_start,frame_ready,pixel_ready,pixel_valid,pixel_last,frame_done,frame_error;
 wire [7:0] pixel_data,gmii_data;wire [63:0] frame_id;
 wire source_fault,mac_busy,mac_done,mac_error,gmii_en,gmii_error,mcu_active,env_valid;
 wire [31:0] frames_done,packets_sent,packets_queued;wire [3:0] error_code;
 // A transport fault blocks new frames as well as lighting the diagnostic LED;
 // an already admitted frame drains, and the PC discards incomplete evidence.
 reg error_seen;
 wire enable=commissioned && phy_configured && link_ready && !phy_fault && !source_fault && !error_seen;
 comms_test_source u_source(.clk(clk125),.reset_n(rst125),.enable(enable),
  .frame_ready(frame_ready),.pixel_ready(pixel_ready),.frame_done(frame_done),.frame_error(frame_error),
  .frame_start(frame_start),.pixel_valid(pixel_valid),.pixel_last(pixel_last),
  .pixel_data(pixel_data),.frame_id(frame_id),.fault(source_fault),.frames_done(frames_done));
 video_network_tx u_network(.clk(clk125),.reset_n(rst125),.enable(enable),
  .frame_start(frame_start),.frame_ready(frame_ready),.stream_epoch(epoch),.frame_id(frame_id),
  .param_version(32'd0),.descriptor_id(32'h54534554),.width(16'd1920),.height(16'd1080),
  .packet_type(8'd1),.bayer_code(8'd1),.pixel_valid(pixel_valid),.pixel_last(pixel_last),
  .pixel_data(pixel_data),.pixel_ready(pixel_ready),.src_mac(src_mac),.dst_mac(dst_mac),
  .src_ip(src_ip),.dst_ip(dst_ip),.src_port(src_port),.dst_port(dst_port),
  .gmii_txd(gmii_data),.gmii_tx_en(gmii_en),.gmii_tx_er(gmii_error),
  .frame_done(frame_done),.frame_error(frame_error),.error_code(error_code),
  .mac_busy(mac_busy),.mac_done(mac_done),.mac_error(mac_error),
  .packets_queued(packets_queued),.packets_sent(packets_sent));
 pango_rgmii_tx #(.PHY_TXID(1)) u_rgmii(.clk125(clk125),.clk125_90(clk125),
  .reset_n(rst125),.txc_reset_n(rst125),.gmii_data(gmii_data),.gmii_en(gmii_en),.gmii_error(gmii_error),
  .rgmii_txc(rgmii_txc),.rgmii_ctl(rgmii_tx_ctl),.rgmii_data(rgmii_txd));
 // Purpose: board monotonic microseconds are distinct from external epoch and
 // MCU timestamps. Low-rate LED heartbeat is not a video-valid assertion.
 reg [6:0] us_div;reg [63:0] time_us;reg [26:0] heartbeat;
 always @(posedge clk125 or negedge rst125)begin
  if(!rst125)begin us_div<=0;time_us<=0;heartbeat<=0;error_seen<=0;end
  else begin
   heartbeat<=heartbeat+1'b1;
   if(us_div==124)begin us_div<=0;time_us<=time_us+1'b1;end else us_div<=us_div+1'b1;
   if(frame_error || mac_error)error_seen<=1;
  end
 end
 wire [31:0] flags={12'd0,phy_fault_code,8'd0,error_seen,source_fault,phy_fault,
                   mcu_active,commissioned,link_ready,phy_configured,1'b1};
 mcu_protocol #(.CLK_HZ(125000000)) u_mcu(.clk(clk125),.rst_n(rst125 && commissioned),
  .uart_rx(uart_rx),.uart_tx(mcu_tx),.link_epoch(epoch),.link_epoch_valid(commissioned),
  .board_time_us(time_us),.status_flags(flags),.session_active(mcu_active),.env_valid(env_valid),
  .env_session_id(),.env_event_seq(),.env_mcu_time_us(),.env_board_time_us(),
  .env_lux_milli(),.env_angle_mdeg(),.env_measurement_valid(),
  .rx_good_count(),.rx_error_count(),.tx_overflow_count());
 // MINI LEDs are active-low: heartbeat / PHY configured / link / commissioned /
 // fault. No pattern here claims that a camera or PC has received a frame.
 assign led=~{(phy_fault||source_fault||error_seen),commissioned,link_ready,phy_configured,heartbeat[25]};
endmodule
