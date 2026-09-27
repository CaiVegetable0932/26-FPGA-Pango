// Purpose: validate one RAW8 sample per DVP clock and pack lossless 256-bit
// writes. A slot must be leased before arm rises; consumers must wait for BOTH
// result_good and the downstream write-drain fence before publishing the slot.
// Address units are 32 bytes, with 2048-byte row stride. Padding is not written
// and must never be transmitted or displayed. No backpressure reaches a sensor.
module raw8_capture #(
 parameter WIDTH=1920, HEIGHT=1080, STRIDE=2048, WARMUP_FRAMES=10,
 parameter SENSOR_EXTRA_ROWS=0
)(
 input wire clk,reset_n,configured,arm,vsync,href,
 input wire [7:0] data,
 output reg frame_start, output reg [63:0] frame_id,
 output reg word_valid, input wire word_ready,
 output reg [255:0] word_data, output reg [16:0] word_offset,
 output reg result_valid, input wire result_ready, output reg result_good,
 output reg [31:0] rejected_frames, overflow_frames,
 output wire [7:0] debug_state
);
 reg vs_d,href_d,active,bad,overflow,closing;
 reg [15:0] columns,rows;
 reg [31:0] warmup;
 reg [63:0] sequence_id;
 reg [255:0] pack;
 // Purpose: source-domain state for the monitor's coherent CDC snapshot.
 assign debug_state={configured,arm,active,bad,closing,result_valid,word_valid,overflow};
 wire start_edge=vs_d && !vsync;
 wire end_edge=!vs_d && vsync;
 wire line_end=href_d && (!href || vsync);
 // Purpose: accept only the requested 1080-row ISP window or the previously
 // measured 1086-row sensor tap. In either case write exactly HEIGHT rows;
 // all widths and every optional tail row remain strictly checked.
 wire [16:0] measured_rows=line_end ? rows+17'd1 : {1'b0,rows};
 wire geometry_ok=(measured_rows==HEIGHT ||
                  (SENSOR_EXTRA_ROWS!=0 && measured_rows==HEIGHT+SENSOR_EXTRA_ROWS)) &&
                  (!line_end || columns==WIDTH);
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   vs_d<=1;href_d<=0;active<=0;bad<=0;overflow<=0;closing<=0;
   columns<=0;rows<=0;warmup<=0;sequence_id<=0;pack<=0;
   frame_start<=0;frame_id<=0;word_valid<=0;word_data<=0;word_offset<=0;
   result_valid<=0;result_good<=0;rejected_frames<=0;overflow_frames<=0;
  end else begin
   vs_d<=vsync;href_d<=href;frame_start<=0;
   if(word_valid && word_ready) word_valid<=0;
   if(result_valid && result_ready) result_valid<=0;
   if(!configured) begin warmup<=0;if(active)bad<=1;end
   // Purpose: source identity advances for every physical frame, including
   // warmup/dropped frames. It is not an Ethernet transmission counter.
   if(start_edge) begin
    sequence_id<=sequence_id+1'b1;
    if(configured && warmup<WARMUP_FRAMES)warmup<=warmup+1'b1;
    if(configured && warmup>=WARMUP_FRAMES && arm && !active &&
       !closing && !result_valid && !word_valid) begin
     active<=1;bad<=0;overflow<=0;rows<=0;columns<=href ? 1 : 0;
     pack<=href ? {248'b0,data} : 256'b0;
     frame_start<=1;frame_id<=sequence_id;
    end else if(configured)rejected_frames<=rejected_frames+1'b1;
   end
   if(active) begin
    if(href && !vsync) begin
     if(columns<WIDTH && rows<HEIGHT) begin
      pack[columns[4:0]*8 +: 8]<=data;
      if(columns[4:0]==31 && !bad) begin
       if(!word_valid || word_ready) begin
        word_data<={data,pack[247:0]};word_valid<=1;
        word_offset<=rows*(STRIDE/32)+(columns>>5);
       end else begin bad<=1;overflow<=1;end
      end
     end else if(columns>=WIDTH || rows>=HEIGHT+SENSOR_EXTRA_ROWS)bad<=1;
     if(columns!=65535)columns<=columns+1'b1;
    end
    if(line_end) begin
     if(columns!=WIDTH || rows>=HEIGHT+SENSOR_EXTRA_ROWS)bad<=1;
     if(rows!=65535)rows<=rows+1'b1;
     columns<=0;
    end
    if(end_edge) begin
     active<=0;closing<=1;
     result_good<=!bad && configured && geometry_ok;
    end
   end
   // Purpose: hold the result until accepted and after our last packed word
   // leaves this stage; downstream FIFO/AXI drain remains a separate fence.
   if(closing && (!word_valid || word_ready)) begin
    closing<=0;result_valid<=1;
    if(!result_good)rejected_frames<=rejected_frames+1'b1;
    if(overflow)overflow_frames<=overflow_frames+1'b1;
   end
  end
 end
endmodule
