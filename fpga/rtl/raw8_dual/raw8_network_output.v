// Purpose: turn a locked, validated RAW8 DDR frame into PRAW/UDP/GMII using the
// proven MAC. All inputs are already in the 125 MHz domain; a native async FIFO
// must bridge the DDR clock. No test-source mux exists in this camera endpoint.
// frame_id/epoch come from capture metadata, never from transmit order.
module raw8_network_output(
 input wire clk,reset_n,enable,frame_start,output wire frame_ready,
 input wire [63:0] stream_epoch,frame_id,
 input wire [31:0] descriptor_id,param_version,
 input wire [255:0] word_data,input wire word_valid,output wire word_ready,
 input wire [47:0] src_mac,dst_mac,input wire [31:0] src_ip,dst_ip,
 input wire [15:0] src_port,dst_port,
 output wire [7:0] gmii_txd,output wire gmii_tx_en,gmii_tx_er,
 output wire frame_done,frame_error,mac_busy,output wire [3:0] error_code
);
 wire tx_ready,unpack_idle,pixel_valid,pixel_ready,pixel_last,praw_error,mac_error;
 wire [3:0] praw_code;
 wire [7:0] pixel_data;
 assign frame_ready=tx_ready && unpack_idle;
 // Purpose: propagate MAC failures as well as PRAW failures to the slot owner;
 // a rejected/underrun Ethernet packet must not look like a successful frame.
 assign frame_error=praw_error || mac_error;
 assign error_code=mac_error ? 4'hf : praw_code;
 // Purpose: admission is atomic across the packetizer and unpacker. Errors
 // require the owner to drain/flush the frame before resetting this endpoint;
 // frame_done alone is not a proof of delivery to the PC.
 raw8_unpack u_unpack(.clk(clk),.reset_n(reset_n),
  .start(frame_start && frame_ready),.idle(unpack_idle),.word_data(word_data),
  .word_valid(word_valid),.word_ready(word_ready),.pixel_data(pixel_data),
  .pixel_valid(pixel_valid),.pixel_last(pixel_last),.pixel_ready(pixel_ready),.done());
 video_network_tx u_network(.clk(clk),.reset_n(reset_n),.enable(enable),
  .frame_start(frame_start && frame_ready),.frame_ready(tx_ready),
  .stream_epoch(stream_epoch),.frame_id(frame_id),.param_version(param_version),
  .descriptor_id(descriptor_id),.width(16'd1920),.height(16'd1080),
  .packet_type(8'd1),.bayer_code(8'd4),.pixel_valid(pixel_valid),.pixel_last(pixel_last),
  .pixel_data(pixel_data),.pixel_ready(pixel_ready),.src_mac(src_mac),.dst_mac(dst_mac),
  .src_ip(src_ip),.dst_ip(dst_ip),.src_port(src_port),.dst_port(dst_port),
  .gmii_txd(gmii_txd),.gmii_tx_en(gmii_tx_en),.gmii_tx_er(gmii_tx_er),
  .frame_done(frame_done),.frame_error(praw_error),.error_code(praw_code),
  .mac_busy(mac_busy),.mac_done(),.mac_error(mac_error),.packets_queued(),.packets_sent());
endmodule
