// Purpose: reusable FPGA communication subsystem, NOT a new board boot image.
// It combines the independent MCU environment UART and the PRAW video sender.
// All metadata and pixel handshakes use clk125; an upstream DDR/frame-pool adapter
// must perform CDC and compact-row reads. Clock/PHY/reset setup is external.
// link_epoch must be fresh and nonzero after each reboot; keep epoch_valid low
// until that is guaranteed. Frame stream_epoch is source identity, not this link.
module fpga_comms_top(
 input wire clk125,clk125_90,reset_n,
 input wire mcu_rx,output wire mcu_tx,
 input wire [63:0] link_epoch,board_time_us,input wire link_epoch_valid,
 input wire [31:0] status_flags,
 output wire mcu_session_active,env_valid,
 output wire [31:0] env_session_id,env_event_seq,env_mcu_time_us,
 output wire [63:0] env_board_time_us,
 output wire [31:0] env_lux_milli,output wire signed [31:0] env_angle_mdeg,
 output wire [1:0] env_measurement_valid,
 output wire [31:0] mcu_rx_good,mcu_rx_errors,mcu_tx_overflow,
 input wire network_enable,frame_start,output wire frame_ready,
 input wire [63:0] stream_epoch,frame_id,input wire [31:0] param_version,descriptor_id,
 input wire [15:0] width,height,input wire [7:0] packet_type,bayer_code,
 input wire pixel_valid,pixel_last,input wire [7:0] pixel_data,output wire pixel_ready,
 input wire [47:0] src_mac,dst_mac,input wire [31:0] src_ip,dst_ip,
 input wire [15:0] src_port,dst_port,
 output wire frame_done,frame_error,output wire [3:0] error_code,
 output wire mac_busy,mac_done,mac_error,
 output wire [31:0] packets_queued,packets_sent,
 output wire rgmii_txc,rgmii_ctl,output wire [3:0] rgmii_data
);
 wire [7:0] gmii_data;wire gmii_en,gmii_error;

 // Purpose: receive CRC-checked, session-qualified environmental observations;
 // commands never trigger motors or change the active video source/parameters.
 mcu_protocol #(.CLK_HZ(125000000),.BAUD(115200)) u_mcu(
  .clk(clk125),.rst_n(reset_n),.uart_rx(mcu_rx),.uart_tx(mcu_tx),
  .link_epoch(link_epoch),.link_epoch_valid(link_epoch_valid),
  .board_time_us(board_time_us),.status_flags(status_flags),
  // Generic integration has no board PHY snapshot and does not advertise bit4.
  .board_diagnostics(96'd0),
  .session_active(mcu_session_active),.env_valid(env_valid),
  .env_session_id(env_session_id),.env_event_seq(env_event_seq),
  .env_mcu_time_us(env_mcu_time_us),.env_board_time_us(env_board_time_us),
  .env_lux_milli(env_lux_milli),.env_angle_mdeg(env_angle_mdeg),
  .env_measurement_valid(env_measurement_valid),.rx_good_count(mcu_rx_good),
  .rx_error_count(mcu_rx_errors),.tx_overflow_count(mcu_tx_overflow));

 // Purpose: accept a completed source frame only when network_enable allows it.
 // The integrator keeps this low until peer registers and a 1Gb/s PHY are ready.
 video_network_tx u_video(
  .clk(clk125),.reset_n(reset_n),.enable(network_enable),
  .frame_start(frame_start),.frame_ready(frame_ready),.stream_epoch(stream_epoch),
  .frame_id(frame_id),.param_version(param_version),.descriptor_id(descriptor_id),
  .width(width),.height(height),.packet_type(packet_type),.bayer_code(bayer_code),
  .pixel_valid(pixel_valid),.pixel_last(pixel_last),.pixel_data(pixel_data),.pixel_ready(pixel_ready),
  .src_mac(src_mac),.dst_mac(dst_mac),.src_ip(src_ip),.dst_ip(dst_ip),
  .src_port(src_port),.dst_port(dst_port),.gmii_txd(gmii_data),.gmii_tx_en(gmii_en),
  .gmii_tx_er(gmii_error),.frame_done(frame_done),.frame_error(frame_error),
  .error_code(error_code),.mac_busy(mac_busy),.mac_done(mac_done),.mac_error(mac_error),
  .packets_queued(packets_queued),.packets_sent(packets_sent));

 // Purpose: use installed PDS native DDR output cells; clk125_90 lags by 2 ns.
 // External PHY TXID, board pins, and output delays still require board sign-off.
 pango_rgmii_tx u_rgmii(.clk125(clk125),.clk125_90(clk125_90),.reset_n(reset_n),
  .gmii_data(gmii_data),.gmii_en(gmii_en),.gmii_error(gmii_error),
  .rgmii_txc(rgmii_txc),.rgmii_ctl(rgmii_ctl),.rgmii_data(rgmii_data));
endmodule
