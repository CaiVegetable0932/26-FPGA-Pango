// Purpose: turn a locked RAW8 DDR frame into PRAW/UDP/GMII using the proven
// MAC. Optional board-side enhancement changes pixel values but not Bayer RAW8
// byte layout; the descriptor/version marks this source distinction. All
// inputs are in the 125 MHz domain; no test-source mux exists here.
// frame_id/epoch come from capture metadata, never from transmit order.
module raw8_network_output #(parameter ENHANCE=0)(
 input wire clk,reset_n,enable,frame_start,discard,output wire frame_ready,source_idle,
 input wire [63:0] stream_epoch,frame_id,
 input wire [31:0] descriptor_id,param_version,
 input wire [255:0] word_data,input wire word_valid,output wire word_ready,
 input wire [47:0] src_mac,dst_mac,input wire [31:0] src_ip,dst_ip,
 input wire [15:0] src_port,dst_port,
 output wire [7:0] gmii_txd,output wire gmii_tx_en,gmii_tx_er,
 output wire frame_done,frame_error,mac_busy,output wire [3:0] error_code
);
 wire tx_ready,unpack_idle,pixel_valid,pixel_ready,pixel_last,praw_error,mac_error;
 wire packet_pixel_ready;
 wire [3:0] praw_code;
 wire [7:0] pixel_data;
 wire [7:0] network_pixel_data;
 reg [7:0] staged_pixel;
 reg staged_valid,staged_last;
 wire stage_ready=!staged_valid || packet_pixel_ready;
 // Purpose: the board endpoint uses the exact HDMI median/tone block before
 // packetization, keeping one Bayer-phase sample and eight bits per pixel.
 // The legacy standalone network regression leaves ENHANCE=0 to validate the
 // unchanged transport independently of the new board-side processing.
 generate if(ENHANCE)begin: g_network_enhance
  reg [10:0] column;
  wire accepted=pixel_valid && pixel_ready && !discard;
  wire line_end=accepted && column==11'd1919;
  always @(posedge clk or negedge reset_n)
   if(!reset_n)column<=0;
   else if(frame_start && frame_ready)column<=0;
   else if(accepted)column<=line_end ? 11'd0 : column+1'b1;
  raw8_display_enhance u_enhance(.clk(clk),.reset_n(reset_n),
   .frame_boundary(frame_start && frame_ready),.line_active(1'b1),
   .line_end(line_end),.pixel_accept(accepted),.sample(pixel_data),
   .luma(network_pixel_data));
 end else begin: g_raw_transport
  assign network_pixel_data=pixel_data;
 end endgenerate
 assign frame_ready=tx_ready && unpack_idle && !staged_valid;
 // Purpose: on transport failure, drain the locked DDR frame without feeding
 // more bytes to PRAW. The owner waits for source_idle plus DMA completion.
 assign pixel_ready=discard || stage_ready;
 assign source_idle=unpack_idle && !staged_valid;
 // Purpose: cut the 125 MHz median/tone-to-PRAW memory combinational path.
 // This one-byte elastic stage accepts and retires together when possible;
 // if the packetizer stalls, it backpressures the unpacker without dropping,
 // duplicating or reordering a byte or the frame-last marker.
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin staged_pixel<=0;staged_valid<=0;staged_last<=0;end
  else if(discard)staged_valid<=0;
  else if(stage_ready)begin
   staged_valid<=pixel_valid;
   if(pixel_valid)begin staged_pixel<=network_pixel_data;staged_last<=pixel_last;end
  end
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
 video_network_tx u_network(.clk(clk),.reset_n(reset_n),.enable(enable && !discard),
  .frame_start(frame_start && frame_ready),.frame_ready(tx_ready),
  .stream_epoch(stream_epoch),.frame_id(frame_id),.param_version(param_version),
  .descriptor_id(descriptor_id),.width(16'd1920),.height(16'd1080),
  .packet_type(8'd1),.bayer_code(8'd4),.pixel_valid(staged_valid && !discard),.pixel_last(staged_last),
  .pixel_data(staged_pixel),.pixel_ready(packet_pixel_ready),.src_mac(src_mac),.dst_mac(dst_mac),
  .src_ip(src_ip),.dst_ip(dst_ip),.src_port(src_port),.dst_port(dst_port),
  .gmii_txd(gmii_txd),.gmii_tx_en(gmii_tx_en),.gmii_tx_er(gmii_tx_er),
  .frame_done(frame_done),.frame_error(praw_error),.error_code(praw_code),
  .mac_busy(mac_busy),.mac_done(),.mac_error(mac_error),.packets_queued(),.packets_sent());
endmodule
