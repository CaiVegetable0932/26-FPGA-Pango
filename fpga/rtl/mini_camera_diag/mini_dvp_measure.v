// Purpose: measure complete post-configuration DVP rows independently of the
// capture abort gate. Preserve the FIRST malformed row's full observed length.
// Counters saturate; a valid frame requires exactly HEIGHT correct-width rows.
module mini_dvp_measure #(parameter WIDTH_BYTES=2560,HEIGHT=720)(
 input wire clk,reset_n,cfg_ready,vsync,href,input wire [7:0] capture_status,
 output wire [159:0] packet);
 reg vp,hp,in_frame,lines_good,first_bad_valid;
 reg [15:0] bytes,rows,first_bad_bytes,first_bad_row,last_frame_rows;
 reg [15:0] good_frames,total_frames,last_line_bytes,bad_frames;
 reg [7:0] reason;
 wire close_line=in_frame && hp && (!href || (vsync && !vp));
 wire [16:0] closed_rows={1'b0,rows}+(hp ? 17'd1 : 17'd0);
 wire complete_geometry=lines_good && closed_rows==HEIGHT && (!hp || bytes==WIDTH_BYTES);
 assign packet={16'hd641,8'h01,capture_status,first_bad_bytes,first_bad_row,
                last_frame_rows,good_frames,total_frames,last_line_bytes,bad_frames,
                reason,7'b0,first_bad_valid};
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   vp<=1;hp<=0;in_frame<=0;lines_good<=1;first_bad_valid<=0;
   bytes<=0;rows<=0;first_bad_bytes<=0;first_bad_row<=0;last_frame_rows<=0;
   good_frames<=0;total_frames<=0;last_line_bytes<=0;bad_frames<=0;reason<=0;
  end else begin
   vp<=vsync;hp<=href;
   if(!cfg_ready) begin
    in_frame<=0;lines_good<=1;first_bad_valid<=0;bytes<=0;rows<=0;
    first_bad_bytes<=0;first_bad_row<=0;last_frame_rows<=0;good_frames<=0;
    total_frames<=0;last_line_bytes<=0;bad_frames<=0;reason<=0;
   end else begin
    if(close_line) begin
     last_line_bytes<=bytes;
     if(rows!=16'hffff)rows<=rows+1'b1;
     if(bytes!=WIDTH_BYTES) begin
      lines_good<=0;
      if(!first_bad_valid) begin
       first_bad_valid<=1;first_bad_bytes<=bytes;first_bad_row<=rows;
       reason<=bytes<WIDTH_BYTES ? 8'd1 : 8'd2;
      end
     end
    end
    if(vsync && !vp) begin
     if(in_frame) begin
      last_frame_rows<=closed_rows>65535 ? 16'hffff : closed_rows[15:0];
      if(total_frames!=16'hffff)total_frames<=total_frames+1'b1;
      if(complete_geometry) begin
       if(good_frames!=16'hffff)good_frames<=good_frames+1'b1;
      end else begin
       if(bad_frames!=16'hffff)bad_frames<=bad_frames+1'b1;
       // Keep a line-width failure above; reason 3 specifically means wrong height.
       if(!first_bad_valid && lines_good && (!hp || bytes==WIDTH_BYTES)) begin
        first_bad_valid<=1;first_bad_bytes<=hp ? bytes : last_line_bytes;
        first_bad_row<=closed_rows[15:0];reason<=3;
       end
      end
     end
     in_frame<=0;bytes<=0;
    end else if(!vsync && vp) begin
     in_frame<=1;lines_good<=1;rows<=0;bytes<=href ? 16'd1 : 16'd0;
    end else if(!vsync && in_frame && href) begin
     if(bytes!=16'hffff)bytes<=bytes+1'b1;
    end else if(!vsync && !href) bytes<=0;
   end
  end
 end
endmodule
