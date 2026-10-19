`timescale 1ns/1ps
// Purpose: complete RAW8 frame -> RGB888 S1 using two 12-bit line memories.
// Dimensions >=2; reflect101 preserves Bayer phase at all four borders.
// Input is an elastic proc-clock stream AFTER the DVP asynchronous FIFO.
// A nonpausable sensor requires upstream peak buffering and whole-frame invalidation.
// RAM read-before-write is intentional (no no_rw_check); mapped collision semantics
// must still be checked in the target PDS netlist before hardware integration.
module raw8_isp #(parameter MAX_WIDTH=2048,parameter TAG_BITS=160)(
 input clk,rst_n,input frame_start,output frame_ready,
 input [15:0] frame_width,frame_height,input [1:0] frame_bayer,
 input [31:0] black_levels,input [63:0] colour_gains,
 input [TAG_BITS-1:0] frame_tag,input frame_abort,
 input in_valid,output in_ready,input [7:0] in_raw,input in_sof,in_eol,
 output out_valid,input out_ready,output [23:0] out_rgb,
 output reg [35:0] out_linear_rgb,
 output [15:0] out_x,out_y,output out_sof,out_eol,out_last,out_mask,
 output [TAG_BITS-1:0] out_tag,output reg frame_error,config_rejected
);
 localparam IDLE=0,INPUT_ROW=1,DRAIN=2,FLUSH=3,NEXT_ROW=4,BOTTOM=5,FINISH=6;
 reg [2:0] state;
 reg [15:0] width,height,x,y;
 reg [1:0] bayer;
 reg [31:0] black;
 reg [63:0] gains;
 reg [TAG_BITS-1:0] saved_tag;
 integer stage_index;
 reg [2:0] gain_valid;
 reg [7:0] clamped0;
 reg [15:0] gain0,gain_x[0:2],gain_y[0:2];
 reg [23:0] gain_product1;
 reg [11:0] corrected2;
 reg ram_valid,ram_first,ram_bottom,ram_parity;
 reg [15:0] ram_x,ram_y;
 reg [11:0] ram_current;
 wire [11:0] line0_q,line1_q;
 reg read_valid;
 reg [15:0] read_x,read_y;
 reg [11:0] rt,rm,rb;
 reg [11:0] tl,tc,ml,mc,bl,bc;
 reg pixel_valid;
 reg [11:0] pr,pg,pb;
 reg [15:0] px,py;
 reg result_valid,result_mask;
 reg [23:0] result_rgb;
 reg [15:0] result_x,result_y;
 wire advance=!result_valid || out_ready;
 wire accept=in_valid && in_ready;
 wire [1:0] phase={y[0],x[0]}^bayer;
 wire [7:0] black_value=black[phase*8+:8];
 wire [7:0] clamped=in_raw>black_value ? in_raw-black_value : 8'd0;
 wire [24:0] gain_rounded={1'b0,gain_product1}+25'd128;
 wire [11:0] corrected=gain_rounded[24:8]>4095 ? 12'd4095 : gain_rounded[19:8];
 wire line_event=gain_valid[2] || state==BOTTOM;
 wire [15:0] line_x=state==BOTTOM ? x : gain_x[2];
 wire [15:0] line_y=state==BOTTOM ? y : gain_y[2];
 isp_line_store #(.DEPTH(MAX_WIDTH)) u_line0(.clk(clk),.enable(advance && line_event),
  .write(gain_valid[2] && !gain_y[2][0]),.address(line_x[$clog2(MAX_WIDTH)-1:0]),.data(corrected2),.q(line0_q));
 isp_line_store #(.DEPTH(MAX_WIDTH)) u_line1(.clk(clk),.enable(advance && line_event),
  .write(gain_valid[2] && gain_y[2][0]),.address(line_x[$clog2(MAX_WIDTH)-1:0]),.data(corrected2),.q(line1_q));
 assign in_ready=state==INPUT_ROW && advance;
 assign frame_ready=state==IDLE && !result_valid && !pixel_valid && !read_valid;
 assign out_valid=result_valid,out_rgb=result_rgb,out_x=result_x,out_y=result_y;
 assign out_sof=result_x==0 && result_y==0,out_eol=result_x==width-1'b1;
 assign out_last=out_eol && result_y==height-1'b1;
 // Per-pixel flags are registered and stable under backpressure; the separate
 // sticky frame_error invalidates the whole descriptor, including older writes.
 assign out_mask=result_mask,out_tag=saved_tag;
 // The same combinational window serves normal arrival and explicit final-column
 // flush. At x=1, the virtual left sample equals x=1, not the opposite colour x=0.
 reg [11:0] w00,w01,w02,w10,w11,w12,w20,w21,w22;
 reg [15:0] wx,wy;
 reg window_valid;
 reg [13:0] cross_sum,diagonal_sum;
 reg [12:0] horizontal_sum,vertical_sum;
 reg [11:0] cross_value,diagonal_value,horizontal_value,vertical_value;
 reg [1:0] window_colour;
 function [7:0] to_rgb8(input [11:0] value);
  reg [12:0] rounded;
  begin rounded={1'b0,value}+13'd8;to_rgb8=rounded[12:4]>255 ? 8'd255 : rounded[11:4];end
 endfunction
 always @* begin
  window_valid=read_valid && read_x!=0;
  wx=read_x-1'b1;wy=read_y;
  w00=read_x==1 ? rt : tl;w01=tc;w02=rt;
  w10=read_x==1 ? rm : ml;w11=mc;w12=rm;
  w20=read_x==1 ? rb : bl;w21=bc;w22=rb;
  if(state==FLUSH && y!=0) begin
   window_valid=1;wx=width-1'b1;wy=y==height ? height-1'b1 : y-1'b1;
   w00=tl;w01=tc;w02=tl;w10=ml;w11=mc;w12=ml;w20=bl;w21=bc;w22=bl;
  end
  cross_sum={2'b0,w01}+{2'b0,w10}+{2'b0,w12}+{2'b0,w21}+14'd2;
  diagonal_sum={2'b0,w00}+{2'b0,w02}+{2'b0,w20}+{2'b0,w22}+14'd2;
  horizontal_sum={1'b0,w10}+{1'b0,w12}+13'd1;
  vertical_sum={1'b0,w01}+{1'b0,w21}+13'd1;
  cross_value=cross_sum[13:2];diagonal_value=diagonal_sum[13:2];
  horizontal_value=horizontal_sum[12:1];vertical_value=vertical_sum[12:1];
  window_colour={wy[0],wx[0]}^bayer;
 end
 // Control and all pipeline state advance together under downstream backpressure.
 // A row boundary drain prevents RAM-return state mixing with the next row.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;gain_valid<=0;ram_valid<=0;read_valid<=0;pixel_valid<=0;result_valid<=0;result_mask<=0;
   frame_error<=0;config_rejected<=0;width<=0;height<=0;x<=0;y<=0;
  end else begin
   config_rejected<=0;
   if(frame_abort && state!=IDLE) frame_error<=1;
   if(frame_start) begin
    if(frame_ready && frame_width>=2 && frame_width<=MAX_WIDTH && frame_height>=2 && frame_height!=16'hffff) begin
     state<=INPUT_ROW;width<=frame_width;height<=frame_height;bayer<=frame_bayer;
     black<=black_levels;gains<=colour_gains;saved_tag<=frame_tag;x<=0;y<=0;frame_error<=0;
    end else config_rejected<=1;
   end
   if(advance) begin
    // Front stages isolate colour mux/black clamp, APM multiplication, saturation
    // and RAM access. Coordinates/valid traverse all stages under the same enable.
    gain_valid<={gain_valid[1:0],accept};
    clamped0<=clamped;gain0<=gains[phase*16+:16];gain_x[0]<=x;gain_y[0]<=y;
    gain_product1<=clamped0*gain0;corrected2<=corrected;
    for(stage_index=1;stage_index<3;stage_index=stage_index+1) begin
     gain_x[stage_index]<=gain_x[stage_index-1];gain_y[stage_index]<=gain_y[stage_index-1];
    end
    ram_valid<=line_event && line_y!=0;
    if(line_event)begin
     ram_x<=line_x;ram_y<=line_y==height ? height-1'b1 : line_y-1'b1;
     ram_first<=line_y==1;ram_bottom<=line_y==height;ram_parity<=line_y[0];ram_current<=corrected2;
    end
    read_valid<=ram_valid;read_x<=ram_x;read_y<=ram_y;
    rt<=ram_first ? ram_current : ram_parity ? line1_q : line0_q;
    rm<=ram_parity ? line0_q : line1_q;
    rb<=ram_bottom ? (ram_parity ? line1_q : line0_q) : ram_current;
    pixel_valid<=window_valid;result_valid<=pixel_valid;
    result_rgb<={to_rgb8(pr),to_rgb8(pg),to_rgb8(pb)};result_x<=px;result_y<=py;
    result_mask<=!frame_error;
    out_linear_rgb<={pr,pg,pb};
    if(window_valid) begin
     px<=wx;py<=wy;
     case(window_colour)
      0:begin pr<=w11;pg<=cross_value;pb<=diagonal_value;end
      3:begin pr<=diagonal_value;pg<=cross_value;pb<=w11;end
      1:begin pr<=horizontal_value;pg<=w11;pb<=vertical_value;end
      2:begin pr<=vertical_value;pg<=w11;pb<=horizontal_value;end
     endcase
    end
    if(read_valid) begin tl<=tc;tc<=rt;ml<=mc;mc<=rm;bl<=bc;bc<=rb;end
    if(accept || state==BOTTOM) begin
     if(accept) begin
      if(in_sof!=(x==0 && y==0) || in_eol!=(x==width-1'b1)) frame_error<=1;
     end
     if(x==width-1'b1) state<=DRAIN;else x<=x+1'b1;
    end
    if(state==DRAIN && gain_valid==0 && !ram_valid && !read_valid) state<=FLUSH;
    if(state==FLUSH) state<=NEXT_ROW;
    if(state==NEXT_ROW) begin
     x<=0;
     if(y==height) state<=FINISH;
     else begin y<=y+1'b1;state<=y==height-1'b1 ? BOTTOM : INPUT_ROW;end
    end
    if(state==FINISH && gain_valid==0 && !ram_valid && !read_valid && !pixel_valid && !result_valid) state<=IDLE;
   end
   // An upstream truncated/overflow frame stops admission and drains emitted
   // pixels; its entire descriptor must be discarded, including earlier writes.
   if(frame_abort && state!=IDLE) state<=FINISH;
  end
 end
endmodule
