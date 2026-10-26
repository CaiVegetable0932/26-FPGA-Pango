`timescale 1ns/1ps
// Purpose: real RAW8 DVP admission plus two independent byte queues. Start and
// EOF are held-data mailboxes, so full byte queues cannot lose cancellation or
// final legality. No second admitted frame can overwrite a live context until
// both consumers drain and the DDR scheduler returns capture_complete.
module camera_frame_cdc #(parameter WIDTH=1920,HEIGHT=1080,WARMUP=10,QUEUE_BITS=13)(
 input pclk,pclk_rst_n,input [7:0] dvp_data,input href,vsync,input camera_ready,
 input [63:0] boot_epoch,
 input memory_clk,memory_rst_n,
 output capture_valid,input capture_ready,input capture_complete,
 output [63:0] epoch,frame_id,capture_first,capture_last,
 output capture_end,isp_legal,raw_legal,output [31:0] capture_errors,
 output isp_abort,raw_abort,
 output isp_valid,input isp_ready,output [7:0] isp_data,
 output raw_valid,input raw_ready,output [7:0] raw_data,
 output queues_drained,output reg source_quiesced,output [31:0] source_frames,dropped_raw,dropped_isp
);
 // Return an explicit stopped-and-drained observation, not an elapsed delay.
 (* syn_preserve=1 *) reg paused_meta,paused_sync;
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin paused_meta<=0;paused_sync<=0;source_quiesced<=0;end
  else begin paused_meta<=!ready_sync && !active;paused_sync<=paused_meta;
   source_quiesced<=paused_sync && queues_drained && !start_pending && !consumed;end
 end
 reg configured,enabled,active,start_toggle,end_toggle,terminal_posted;
 reg [63:0] source_id;
 reg [191:0] start_held;reg [97:0] end_held;
 reg [63:0] epoch_local;reg epoch_loaded;
 reg [191:0] start_local;reg [97:0] end_local;
 reg start_pending,end_pending;
 reg raw_bad,isp_bad;
 reg acknowledge,consumed;
 (* syn_preserve=1 *) reg ack_meta,ack_sync,ready_meta,ready_sync;
 (* syn_preserve=1 *) reg start_meta,start_sync,end_meta,end_sync;
 (* syn_preserve=1 *) reg raw_bad_meta,raw_bad_sync,isp_bad_meta,isp_bad_sync;
 wire cfg_ready,cfg_accepted;
 wire pixel_valid,frame_start,frame_admitted,frame_abort,frame_end,frame_legal;
 wire [15:0] pixel_data,pixel_x,pixel_y,frame_errors;
 wire pixel_sof,pixel_eol,pixel_last;
 wire [127:0] frame_tag;
 wire [63:0] first_ticks,last_ticks;
 wire raw_push,isp_push,raw_space,isp_space;
 wire fan_raw_abort,fan_isp_abort,fan_raw_end,fan_isp_end,fan_raw_legal,fan_isp_legal;
 wire raw_empty,isp_empty;
 // Register bundled payloads once their synchronized toggles arrive. All
 // downstream frame/abort/ownership logic sees ordinary memory-domain buses.
 assign epoch=start_local[191:128],frame_id=start_local[127:64],capture_first=start_local[63:0];
 assign capture_last=end_local[97:34],capture_errors=end_local[33:2];
 assign isp_legal=end_local[1],raw_legal=end_local[0];
 assign capture_valid=start_pending && !consumed;
 assign capture_end=consumed && end_pending;
 assign raw_abort=consumed && raw_bad_sync,isp_abort=consumed && isp_bad_sync;
 assign queues_drained=raw_empty && isp_empty;
 dvp_frame_receiver #(.FORMAT(1),.MAX_WIDTH(WIDTH),.MAX_HEIGHT(HEIGHT),.TAG_BITS(128),
  .WARMUP_FRAMES(WARMUP)) receiver(.pclk(pclk),.rst_n(pclk_rst_n),.dvp_data(dvp_data),.href(href),.vsync(vsync),
  .capture_enable(enabled && ready_sync && epoch_loaded),.pipeline_drained(!active),
  .cfg_valid(!configured && cfg_ready),.cfg_ready(cfg_ready),.cfg_width(WIDTH[15:0]),.cfg_height(HEIGHT[15:0]),
  .cfg_bayer(3'd4),.cfg_version(32'd1),.cfg_entity(32'd1),.cfg_accepted(cfg_accepted),.cfg_rejected(),
  .token_valid(!active),.next_frame_tag({epoch_local,source_id+64'd1}),.input_overflow(1'b0),
  .pixel_valid(pixel_valid),.pixel_data(pixel_data),.pixel_x(pixel_x),.pixel_y(pixel_y),
  .pixel_sof(pixel_sof),.pixel_eol(pixel_eol),.pixel_last(pixel_last),.pixel_phase(),.pixel_tag(),
  .frame_start(frame_start),.frame_admitted(frame_admitted),.frame_abort(frame_abort),.frame_end(frame_end),
  .frame_legal(frame_legal),.frame_errors(frame_errors),.frame_tag(frame_tag),.frame_version(),.frame_entity(),
  .capture_first(first_ticks),.capture_last(last_ticks),.source_frames(source_frames),.valid_frames(),.error_frames(),
  .warmup_frames(),.last_frame_bytes(),.last_frame_pixels(),.last_frame_ticks(),.last_frame_lines());
 dvp_raw8_fanout #(.TAG_BITS(128)) fanout(.pclk(pclk),.rst_n(pclk_rst_n),.frame_start(frame_start),
  .frame_admitted(frame_admitted),.frame_abort(frame_abort),.frame_end(frame_end),.frame_legal(frame_legal),
  .raw_admit(1'b1),.isp_admit(1'b1),.in_valid(pixel_valid),.in_raw(pixel_data[7:0]),
  .in_x(pixel_x),.in_y(pixel_y),.in_sof(pixel_sof),.in_eol(pixel_eol),.in_last(pixel_last),.in_tag(frame_tag),
  .raw_ready(raw_space),.isp_ready(isp_space),.raw_valid(raw_push),.isp_valid(isp_push),.raw_data(),.isp_data(),
  .out_x(),.out_y(),.out_sof(),.out_eol(),.out_last(),.out_tag(),
  .raw_abort(fan_raw_abort),.isp_abort(fan_isp_abort),.raw_end(fan_raw_end),.isp_end(fan_isp_end),
  .raw_legal(fan_raw_legal),.isp_legal(fan_isp_legal),.raw_dropped_frames(dropped_raw),.isp_dropped_frames(dropped_isp));
 async_stream_fifo #(.ADDRESS_BITS(QUEUE_BITS)) raw_queue(.write_clk(pclk),.write_rst_n(pclk_rst_n),.write_valid(raw_push),.write_ready(raw_space),
  .write_data(pixel_data[7:0]),.read_clk(memory_clk),.read_rst_n(memory_rst_n),.read_valid(raw_valid),
  .read_ready(raw_ready),.read_data(raw_data),.drained(raw_empty));
 async_stream_fifo #(.ADDRESS_BITS(QUEUE_BITS)) isp_queue(.write_clk(pclk),.write_rst_n(pclk_rst_n),.write_valid(isp_push),.write_ready(isp_space),
  .write_data(pixel_data[7:0]),.read_clk(memory_clk),.read_rst_n(memory_rst_n),.read_valid(isp_valid),
  .read_ready(isp_ready),.read_data(isp_data),.drained(isp_empty));
 // Source identities count every detected sensor frame, including warmup and
 // drops. Mailbox contents change only before their toggle and remain frozen
 // until the scheduler's final drain acknowledgement returns to PCLK.
 always @(posedge pclk or negedge pclk_rst_n)begin
  if(!pclk_rst_n)begin configured<=0;enabled<=0;active<=0;start_toggle<=0;end_toggle<=0;source_id<=0;
   start_held<=0;end_held<=0;epoch_local<=0;epoch_loaded<=0;raw_bad<=0;isp_bad<=0;terminal_posted<=0;ack_meta<=0;ack_sync<=0;ready_meta<=0;ready_sync<=0;end
  else begin
   ack_meta<=acknowledge;ack_sync<=ack_meta;ready_meta<=camera_ready;ready_sync<=ready_meta;
   // Boot data stays immutable before commissioning and until joint reset.
   // Capture it only after the synchronized commissioning level, then use
   // this PCLK register for every receiver tag and source mailbox.
   if(ready_sync && !epoch_loaded)begin epoch_local<=boot_epoch;epoch_loaded<=1;end
   if(cfg_accepted)begin configured<=1;enabled<=1;end
   if(frame_start)begin
    if(source_id!=64'hffffffffffffffff)source_id<=source_id+1'b1;
    if(frame_admitted)begin active<=1;start_toggle<=!start_toggle;start_held<={frame_tag,first_ticks};raw_bad<=0;isp_bad<=0;terminal_posted<=0;end
   end
   if(active)begin
    if(fan_raw_abort)raw_bad<=1;if(fan_isp_abort)isp_bad<=1;
    // Later unadmitted sensor frames cannot overwrite this context's EOF.
    if(fan_raw_end && fan_isp_end && !terminal_posted)begin
     end_held<={last_ticks,16'd0,frame_errors,fan_isp_legal && !isp_bad,fan_raw_legal && !raw_bad};end_toggle<=start_toggle;
     terminal_posted<=1;
    end
    if(ack_sync==start_toggle)active<=0;
   end
  end
 end
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin acknowledge<=0;consumed<=0;start_meta<=0;start_sync<=0;end_meta<=0;end_sync<=0;
   raw_bad_meta<=0;raw_bad_sync<=0;isp_bad_meta<=0;isp_bad_sync<=0;
   start_local<=0;end_local<=0;start_pending<=0;end_pending<=0;end
  else begin
   start_meta<=start_toggle;start_sync<=start_meta;end_meta<=end_toggle;end_sync<=end_meta;
   raw_bad_meta<=raw_bad;raw_bad_sync<=raw_bad_meta;isp_bad_meta<=isp_bad;isp_bad_sync<=isp_bad_meta;
   if(start_sync!=acknowledge && !start_pending)begin start_local<=start_held;start_pending<=1;end
   if(start_pending && end_sync==start_sync && !end_pending)begin end_local<=end_held;end_pending<=1;end
   if(capture_valid && capture_ready)consumed<=1;
   if(capture_complete)begin acknowledge<=start_sync;consumed<=0;start_pending<=0;end_pending<=0;end
  end
 end
endmodule
