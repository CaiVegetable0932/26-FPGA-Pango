// Purpose: observe the real sampled DVP independently of capture admission.
// Count HREF widths in BOTH VSYNC phases; never change video/lease signals.
// Periodic bundled-data request/ack transfers a coherent snapshot even when
// frames are malformed. A stopped camera clock leaves the last snapshot stale.
module raw8_dvp_monitor #(parameter POLL_BITS=20)(
 input wire cam_clk,cam_reset_n,mem_clk,mem_reset_n,vsync,href,
 input wire [7:0] capture_state,input wire [31:0] rejected,overflows,
 output reg [95:0] geometry,progress
);
 reg vs_d,href_d,line_phase;
 reg [15:0] width_count,low_lines,high_lines,min_width,max_width,frames;
 reg [15:0] last_low,last_high,last_min,last_max;
 reg [31:0] clocks;
 wire line_end=href_d && !href;
 wire low_end=line_end && !line_phase;
 wire high_end=line_end && line_phase;
 wire boundary=vs_d && !vsync;
 // Purpose: include a HREF falling on the same edge as VSYNC's new interval.
 wire [15:0] end_low=low_lines+{15'b0,low_end && low_lines!=16'hffff};
 wire [15:0] end_high=high_lines+{15'b0,high_end && high_lines!=16'hffff};
 wire [15:0] end_min=(low_end && width_count<min_width)?width_count:min_width;
 wire [15:0] end_max=(low_end && width_count>max_width)?width_count:max_width;
 reg request,ack,busy;
 (* syn_preserve=1 *) reg req_meta,req_sync,ack_meta,ack_sync;
 (* syn_preserve=1 *) reg [191:0] held;
 reg [POLL_BITS-1:0] divider;
 always @(posedge cam_clk or negedge cam_reset_n)
  if(!cam_reset_n)begin
   vs_d<=1;href_d<=0;line_phase<=0;width_count<=0;low_lines<=0;high_lines<=0;
   min_width<=16'hffff;max_width<=0;frames<=0;clocks<=0;
   last_low<=0;last_high<=0;last_min<=0;last_max<=0;
   req_meta<=0;req_sync<=0;ack<=0;held<=0;
  end else begin
   vs_d<=vsync;href_d<=href;clocks<=clocks+1'b1;
   req_meta<=request;req_sync<=req_meta;
   if(href)begin
    if(!href_d)begin width_count<=1;line_phase<=vsync;end
    else if(width_count!=16'hffff)width_count<=width_count+1'b1;
   end
   if(line_end)begin
    low_lines<=end_low;high_lines<=end_high;min_width<=end_min;max_width<=end_max;
    width_count<=0;
   end
   if(boundary)begin
    frames<=frames+1'b1;last_low<=end_low;last_high<=end_high;
    last_min<=end_low==0?16'b0:end_min;last_max<=end_max;
    low_lines<=0;high_lines<=0;min_width<=16'hffff;max_width<=0;
   end
   // Hold all payload bits until the NEXT request, not merely until ACK.
   // The receiving ACK has two synchronizer stages before data is sampled.
   if(req_sync!=ack)begin
    held<={overflows,rejected,clocks,8'd1,capture_state,
           last_high,last_max,last_min,last_low,frames};
    ack<=req_sync;
   end
  end
 always @(posedge mem_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin request<=0;busy<=0;ack_meta<=0;ack_sync<=0;
   divider<=0;geometry<=0;progress<=0;end
  else begin
   divider<=divider+1'b1;ack_meta<=ack;ack_sync<=ack_meta;
   if(divider==0 && !busy)begin request<=!request;busy<=1;end
   if(busy && ack_sync==request)begin
    geometry<=held[95:0];progress<=held[191:96];busy<=0;
   end
  end
endmodule
