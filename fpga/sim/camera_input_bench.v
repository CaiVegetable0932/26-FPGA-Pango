`timescale 1ns/1ps
// 用途：内部100MHz预算下的RAW8接收/独立分流路径综合与路由基准；源由片内计数器生成。
// 没有真实相机引脚/DDR/ISP FIFO，也不包含外部DVP延时或CDC物理签核，禁止作为板级工程下载。
module camera_input_bench(
 input wire clk,rst_in,input wire [7:0] seed,input wire raw_available,isp_available,
 output reg [31:0] checksum,output wire [31:0] good_frames,bad_frames,
 output wire [1:0] branch_legal,output wire clock_lost
);
 wire rst_n;reset_sync reset_domain(clk,rst_in,rst_n);
 reg [5:0] boot;reg [11:0] column;reg [10:0] row;
 reg [31:0] source_id;
 wire cfg=boot==8;wire enable=boot>=16;
 wire h=enable && row<1080 && column<1920;
 wire v=!enable || row>=1080;
 wire [7:0] sample=column[7:0]^row[7:0]^seed;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin boot<=0;column<=0;row<=1124;source_id<=0;end
  else begin
   if(boot!=63)boot<=boot+1'b1;
   if(enable)begin
    if(column==2047)begin
     column<=0;
     if(row==1124)begin row<=0;source_id<=source_id+1'b1;end else row<=row+1'b1;
    end else column<=column+1'b1;
   end
  end
 wire pv,sof,eol,last,fs,admitted,abort,finish,legal;
 wire [15:0] data,x,y,errors;wire [159:0] tag;
 wire [31:0] version,entity,source_count,warm_count,byte_count,pixel_count,frame_ticks;
 wire [63:0] first_time,last_time;
 wire [15:0] line_count;
 dvp_frame_receiver #(.WARMUP_FRAMES(1)) receiver(
 .pclk(clk),.rst_n(rst_n),.dvp_data(sample),.href(h),.vsync(v),.capture_enable(enable),
 .pipeline_drained(1'b1),.cfg_valid(cfg),.cfg_width(16'd1920),.cfg_height(16'd1080),.cfg_bayer(3'd1),
 .cfg_version({24'b0,seed}),.cfg_entity({24'b0,seed}),.token_valid(1'b1),
 .next_frame_tag({source_id,source_id^32'h1,source_id^32'h2,source_id^32'h3,source_id^32'h4}),.input_overflow(1'b0),
 .pixel_valid(pv),.pixel_data(data),.pixel_x(x),.pixel_y(y),.pixel_sof(sof),.pixel_eol(eol),.pixel_last(last),.pixel_tag(tag),
 .frame_start(fs),.frame_admitted(admitted),.frame_abort(abort),.frame_end(finish),.frame_legal(legal),
 .frame_errors(errors),.frame_version(version),.frame_entity(entity),.capture_first(first_time),.capture_last(last_time),
 .source_frames(source_count),.valid_frames(good_frames),.error_frames(bad_frames),.warmup_frames(warm_count),
 .last_frame_bytes(byte_count),.last_frame_pixels(pixel_count),.last_frame_ticks(frame_ticks),.last_frame_lines(line_count));
 wire rv,iv,raw_abort,isp_abort,re,ie,rl,il;wire [31:0] raw_drops,isp_drops;
 dvp_raw8_fanout fork_path(.pclk(clk),.rst_n(rst_n),.frame_start(fs),.frame_admitted(admitted),.frame_abort(abort),
 .frame_end(finish),.frame_legal(legal),.raw_admit(1'b1),.isp_admit(1'b1),
 .in_valid(pv),.in_raw(data[7:0]),.in_x(x),.in_y(y),.in_sof(sof),.in_eol(eol),.in_last(last),.in_tag(tag),
 .raw_ready(raw_available),.isp_ready(isp_available),.raw_valid(rv),.isp_valid(iv),
 .raw_abort(raw_abort),.isp_abort(isp_abort),.raw_end(re),.isp_end(ie),.raw_legal(rl),.isp_legal(il),
 .raw_dropped_frames(raw_drops),.isp_dropped_frames(isp_drops));
 assign branch_legal={il,rl};
 dvp_clock_watchdog watchdog(.pclk(clk),.pclk_reset_n(rst_n),.ctrl_clk(clk),.ctrl_reset_n(rst_n),
 .enable(enable),.clock_lost(clock_lost),.loss_event());
 // 哈希观测所有数据/tag/错误/快照字段，防止基准无用逻辑被整体裁掉；不当作视频验收。
 always @(posedge clk or negedge rst_n)
  if(!rst_n)checksum<=0;
  else if(pv || finish)checksum<=checksum^{x,y}^{16'b0,data}^tag[31:0]^tag[63:32]^tag[95:64]^tag[127:96]^tag[159:128]^
   version^entity^first_time[31:0]^first_time[63:32]^last_time[31:0]^last_time[63:32]^
   source_count^warm_count^byte_count^pixel_count^frame_ticks^{line_count,errors}^raw_drops^isp_drops^
   {23'b0,rv,iv,raw_abort,isp_abort,re,ie,sof,eol,last};
endmodule
