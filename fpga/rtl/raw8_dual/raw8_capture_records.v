// Purpose: ordered START/WORD/END records through a native async FIFO. The
// memory-domain lease level is acknowledged once, before waiting for another.
// START/END cannot be bypassed by pixel words, even when the queue is full.
// Warmup remains ten real frames on the board; tests may shorten it explicitly.
module raw8_capture_records #(parameter WARMUP_FRAMES=10,
 parameter SENSOR_EXTRA_ROWS=0)(
 input wire cam_clk,cam_reset_n,configured,lease_valid,
 input wire vsync,href,input wire [7:0] data,
 output reg lease_ack,output wire [287:0] record_data,
 output wire record_valid,input wire record_ready,
 output wire [31:0] rejected,overflows,output wire [7:0] debug_state
);
 (* syn_preserve=1 *) reg lease_meta,lease_sync,cfg_meta,cfg_sync;
 wire start,wvalid,result,good;wire [63:0] fid;
 wire [255:0] word;wire [16:0] offset;
 reg start_pending;
 always @(posedge cam_clk or negedge cam_reset_n)
  if(!cam_reset_n)begin lease_meta<=0;lease_sync<=0;cfg_meta<=0;cfg_sync<=0;lease_ack<=0;start_pending<=0;end
  else begin
   lease_meta<=lease_valid;lease_sync<=lease_meta;cfg_meta<=configured;cfg_sync<=cfg_meta;
   if(!lease_sync)lease_ack<=0;
   if(start)begin lease_ack<=1;start_pending<=1;end
   if(start_pending && record_ready)start_pending<=0;
  end
 assign record_valid=start_pending || wvalid || result;
 // Record: tag[287:286] 1=START,0=WORD,2=END; offset[272:256];
 // payload WORD[255:0], START/END frame_id[63:0], END good[64].
 assign record_data=start_pending ? {2'd1,222'b0,fid} :
                    wvalid ? {15'b0,offset,word} : {2'd2,221'b0,good,fid};
 // Purpose: propagate physical sensor geometry to the board's capture path.
 raw8_capture #(.WARMUP_FRAMES(WARMUP_FRAMES),
  .SENSOR_EXTRA_ROWS(SENSOR_EXTRA_ROWS)) u_capture(.clk(cam_clk),.reset_n(cam_reset_n),.configured(cfg_sync),
  .arm(lease_sync && !lease_ack),.vsync(vsync),.href(href),.data(data),
  .frame_start(start),.frame_id(fid),.word_valid(wvalid),
  .word_ready(record_ready && !start_pending),.word_data(word),.word_offset(offset),
  .result_valid(result),.result_ready(record_ready && !start_pending && !wvalid),
  .result_good(good),.rejected_frames(rejected),.overflow_frames(overflows),.debug_state(debug_state));
endmodule
