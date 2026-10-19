`timescale 1ns/1ps
// 用途：PCLK 域不可暂停 DVP 的完整帧判定；RAW8 与 RGB565 通过独立实例参数明确区分。
// 数据/边界先同拍寄存，再计数/打包；所有输出为暂存数据，直到 frame_end/legal 才可 seal。
// TAG 由03预分配并在帧起点锁存；此模块不擅自生成外部 epoch/frame_id 或 DDR 完成。
module dvp_frame_receiver #(
 parameter integer FORMAT=1, // 1=RAW8；2=RGB565 诊断，内部枚举不用于网络协议。
 parameter integer MAX_WIDTH=1920, MAX_HEIGHT=1080, TAG_BITS=160,
 parameter integer WARMUP_FRAMES=10,
 parameter integer FRAME_TIMEOUT=4000000, LINE_TIMEOUT=10000
)(
 input wire pclk,rst_n,input wire [7:0] dvp_data,input wire href,vsync,
 // 全部配置/控制/标签输入必须已经在 PCLK 域完成握手，禁止直接逐位同步跨域总线。
 input wire capture_enable,input wire pipeline_drained,
 input wire cfg_valid,output wire cfg_ready,input wire [15:0] cfg_width,cfg_height,
 input wire [2:0] cfg_bayer,input wire [31:0] cfg_version,cfg_entity,
 output reg cfg_accepted,cfg_rejected,
 input wire token_valid,input wire [TAG_BITS-1:0] next_frame_tag,
 input wire input_overflow,
 output reg pixel_valid,output reg [15:0] pixel_data,pixel_x,pixel_y,
 output reg pixel_sof,pixel_eol,pixel_last,output reg [1:0] pixel_phase,
 output wire [TAG_BITS-1:0] pixel_tag,
 output reg frame_start,frame_admitted,frame_abort,frame_end,frame_legal,
 output reg [15:0] frame_errors,output reg [TAG_BITS-1:0] frame_tag,
 output reg [31:0] frame_version,frame_entity,
 output reg [63:0] capture_first,capture_last,
 output reg [31:0] source_frames,valid_frames,error_frames,warmup_frames,
 output reg [31:0] last_frame_bytes,last_frame_pixels,last_frame_ticks,
 output reg [15:0] last_frame_lines
);
 localparam integer BPP=FORMAT==2 ? 2 : 1;
 localparam integer BC_BITS=$clog2(MAX_WIDTH*BPP+2),LC_BITS=$clog2(MAX_HEIGHT+2);
 // 错误位内部约定：短行/长行/缺行/多行/边界/超时/溢出/就绪掉线/无配置/无令牌。
 localparam [15:0] SHORT_LINE=16'h0001,LONG_LINE=16'h0002,SHORT_FRAME=16'h0004,
  LONG_FRAME=16'h0008,BOUNDARY=16'h0010,TIMEOUT=16'h0020,OVERFLOW=16'h0040,
  DISABLED=16'h0080,NO_CONFIG=16'h0100,NO_TOKEN=16'h0200;
 reg [7:0] data_s;reg href_s,vs_s,hprev,vprev;
 reg configured,open_frame,line_open,admitted,aborted;
 reg [15:0] width,height;reg [2:0] bayer;
 reg [31:0] version,entity;
 reg [BC_BITS-1:0] bytes_in_line;
 reg [LC_BITS-1:0] lines;
 reg [31:0] frame_ticks,line_ticks,byte_total,pixel_total;
 reg [31:0] warmup_left;
 reg [63:0] ticks;
 reg [7:0] first_byte;
 reg [15:0] errors;
 wire start_edge=vprev && !vs_s;
 wire end_edge=!vprev && vs_s;
 wire fall_line=hprev && !href_s;
 wire [16:0] expected_bytes={1'b0,width}*BPP;
 assign cfg_ready=!capture_enable && pipeline_drained && !open_frame;
 assign pixel_tag=frame_tag;
 // 源同步采样保持数据/HREF/VSYNC一起前进；两级同步仅应用于外部控制适配器。
 always @(posedge pclk or negedge rst_n)
  if(!rst_n)begin data_s<=0;href_s<=0;vs_s<=1;hprev<=0;vprev<=1;end
  else begin data_s<=dvp_data;href_s<=href;vs_s<=vsync;hprev<=href_s;vprev<=vs_s;end

 // 先计算同拍最终行数和错误，确保 HREF 下降沿与 VSYNC 上升沿同拍不会漏末行。
 reg [15:0] next_errors;
 reg [LC_BITS-1:0] ended_lines;
 wire timeout_now=frame_ticks>=FRAME_TIMEOUT-1 || (line_open && line_ticks>=LINE_TIMEOUT-1);
 always @* begin
  next_errors=errors;ended_lines=lines;
  if(open_frame)begin
   if(!capture_enable)next_errors=next_errors|DISABLED;
   if(input_overflow)next_errors=next_errors|OVERFLOW;
   if(timeout_now)next_errors=next_errors|TIMEOUT;
   if(href_s && vs_s)next_errors=next_errors|BOUNDARY;
   if(href_s && !vs_s)begin
    if(lines>=height)next_errors=next_errors|LONG_FRAME;
    if(bytes_in_line>=expected_bytes)next_errors=next_errors|LONG_LINE;
   end
   if(line_open && (fall_line || end_edge))begin
    if(bytes_in_line<expected_bytes)next_errors=next_errors|SHORT_LINE;
    if(bytes_in_line>expected_bytes)next_errors=next_errors|LONG_LINE;
    if(lines<MAX_HEIGHT+1)ended_lines=lines+1'b1;
   end
   if(end_edge)begin
    if(ended_lines<height)next_errors=next_errors|SHORT_FRAME;
    if(ended_lines>height)next_errors=next_errors|LONG_FRAME;
   end
  end
 end

 // 全速 RAW8 II=1；RGB565 两字节一个像素。坏帧立即停止输出并发 abort，但仍排空到边界。
 always @(posedge pclk or negedge rst_n)begin
  if(!rst_n)begin
   configured<=0;open_frame<=0;line_open<=0;admitted<=0;aborted<=0;
   width<=0;height<=0;bayer<=0;version<=0;entity<=0;bytes_in_line<=0;lines<=0;
   frame_ticks<=0;line_ticks<=0;byte_total<=0;pixel_total<=0;warmup_left<=WARMUP_FRAMES;
   ticks<=0;first_byte<=0;errors<=0;pixel_valid<=0;pixel_data<=0;pixel_x<=0;pixel_y<=0;
   pixel_sof<=0;pixel_eol<=0;pixel_last<=0;pixel_phase<=0;
   cfg_accepted<=0;cfg_rejected<=0;frame_start<=0;frame_admitted<=0;
   frame_abort<=0;frame_end<=0;frame_legal<=0;frame_errors<=0;frame_tag<=0;
   frame_version<=0;frame_entity<=0;capture_first<=0;capture_last<=0;
   source_frames<=0;valid_frames<=0;error_frames<=0;warmup_frames<=0;
   last_frame_bytes<=0;last_frame_pixels<=0;last_frame_ticks<=0;last_frame_lines<=0;
  end else begin
   ticks<=ticks+1'b1;
   pixel_valid<=0;pixel_sof<=0;pixel_eol<=0;pixel_last<=0;
   frame_start<=0;frame_abort<=0;frame_end<=0;frame_legal<=0;
   cfg_accepted<=0;cfg_rejected<=0;
   if(cfg_valid)begin
    if(cfg_ready && (FORMAT==1 || FORMAT==2) && cfg_width>0 && cfg_width<=MAX_WIDTH &&
       cfg_height>0 && cfg_height<=MAX_HEIGHT && (FORMAT==2 || (cfg_bayer>=1 && cfg_bayer<=4)) &&
       FRAME_TIMEOUT>1 && LINE_TIMEOUT>1)begin
     configured<=1;width<=cfg_width;height<=cfg_height;bayer<=cfg_bayer;
     version<=cfg_version;entity<=cfg_entity;warmup_left<=WARMUP_FRAMES;cfg_accepted<=1;
    end else cfg_rejected<=1;
   end
   if(!capture_enable)warmup_left<=WARMUP_FRAMES;
   if(start_edge && !open_frame)begin
    // 同拍VSYNC释放/HREF起点的首字节也计入帧；HREF跨越整个消隐才标边界错误。
    open_frame<=1;frame_start<=1;frame_tag<=next_frame_tag;
    frame_version<=version;frame_entity<=entity;capture_first<=ticks;
    frame_ticks<=0;line_ticks<=0;bytes_in_line<=href_s ? 1 : 0;lines<=0;line_open<=href_s;
    byte_total<=href_s ? 1 : 0;pixel_total<=(href_s && FORMAT==1) ? 1 : 0;aborted<=0;source_frames<=source_frames+1'b1;
    errors<=(!configured ? NO_CONFIG : 0) | (!capture_enable ? DISABLED : 0) |
            (href_s && hprev ? BOUNDARY : 0) | ((warmup_left==0 && !token_valid) ? NO_TOKEN : 0);
    admitted<=configured && capture_enable && warmup_left==0 && token_valid && !(href_s && hprev);
    frame_admitted<=configured && capture_enable && warmup_left==0 && token_valid && !(href_s && hprev);
    if(href_s && !hprev)begin
     first_byte<=data_s;
     if(FORMAT==1 && configured && capture_enable && warmup_left==0 && token_valid)begin
      pixel_valid<=1;pixel_data<={8'b0,data_s};pixel_x<=0;pixel_y<=0;pixel_sof<=1;
      pixel_eol<=width==1;pixel_last<=width==1 && height==1;pixel_phase<=bayer-1'b1;
     end
    end
   end else if(open_frame)begin
    frame_ticks<=frame_ticks+1'b1;errors<=next_errors;
    if(line_open)line_ticks<=line_ticks+1'b1;
    if(next_errors!=0 && !aborted)begin frame_abort<=1;aborted<=1;end
    if(fall_line)begin
     line_open<=0;bytes_in_line<=0;line_ticks<=0;lines<=ended_lines;
    end
    if(href_s && !vs_s)begin
     line_open<=1;
     if(!hprev)line_ticks<=0;
     if(bytes_in_line<MAX_WIDTH*BPP+1)bytes_in_line<=bytes_in_line+1'b1;
     if(byte_total!=32'hffffffff)byte_total<=byte_total+1'b1;
     if(bytes_in_line<expected_bytes && lines<height && next_errors==0)begin
      if(FORMAT==2 && !bytes_in_line[0])first_byte<=data_s;
      if(FORMAT==1 || bytes_in_line[0])begin
       pixel_total<=pixel_total+1'b1;
       pixel_valid<=admitted;
       pixel_data<=FORMAT==1 ? {8'b0,data_s} : {first_byte,data_s};
       pixel_x<=FORMAT==1 ? bytes_in_line : bytes_in_line>>1;
       pixel_y<=lines;
       pixel_sof<=admitted && lines==0 && bytes_in_line==BPP-1;
       pixel_eol<=admitted && bytes_in_line==expected_bytes-1;
       pixel_last<=admitted && bytes_in_line==expected_bytes-1 && lines==height-1;
       pixel_phase<={lines[0],(FORMAT==1 ? bytes_in_line[0] : bytes_in_line[1])} ^ (bayer-1'b1);
      end
     end
    end
    if(end_edge || timeout_now || !capture_enable)begin
     frame_end<=1;frame_errors<=next_errors;capture_last<=ticks;
     frame_legal<=admitted && next_errors==0;
     last_frame_bytes<=byte_total;last_frame_pixels<=pixel_total;
     last_frame_ticks<=frame_ticks;last_frame_lines<=ended_lines;
     open_frame<=0;line_open<=0;admitted<=0;
     if(next_errors!=0)begin error_frames<=error_frames+1'b1;if(warmup_left!=0)warmup_left<=WARMUP_FRAMES;end
     else if(warmup_left!=0)begin warmup_frames<=warmup_frames+1'b1;warmup_left<=warmup_left-1'b1;end
     else if(admitted)valid_frames<=valid_frames+1'b1;
    end
   end
  end
 end
endmodule
