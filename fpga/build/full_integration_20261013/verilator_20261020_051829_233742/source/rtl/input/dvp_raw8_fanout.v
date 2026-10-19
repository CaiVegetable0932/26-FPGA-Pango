`timescale 1ns/1ps
// 用途：PCLK 域并行分流到 RAW 导出队列和 ISP 主视频队列，不增加 DDR RAW 读回流量。
// ready 为各队列写侧容量，DVP 不能暂停；满队列只作废对应支路，直到下一帧且获得新令牌。
// frame_end/branch_legal 只是输入 seal 条件；03仍必须等待04真实写完成/取消排空。
module dvp_raw8_fanout #(parameter TAG_BITS=160)(
 input wire pclk,rst_n,input wire frame_start,frame_admitted,frame_abort,frame_end,frame_legal,
 input wire raw_admit,isp_admit,
 input wire in_valid,input wire [7:0] in_raw,input wire [15:0] in_x,in_y,
 input wire in_sof,in_eol,in_last,input wire [TAG_BITS-1:0] in_tag,
 input wire raw_ready,isp_ready,
 output wire raw_valid,isp_valid,output wire [7:0] raw_data,isp_data,
 output wire [15:0] out_x,out_y,output wire out_sof,out_eol,out_last,
 output wire [TAG_BITS-1:0] out_tag,
 output reg raw_abort,isp_abort,raw_end,isp_end,raw_legal,isp_legal,
 output reg [31:0] raw_dropped_frames,isp_dropped_frames
);
 reg raw_live,isp_live,raw_counted,isp_counted;
 wire rlive=frame_start ? frame_admitted && raw_admit : raw_live;
 wire ilive=frame_start ? frame_admitted && isp_admit : isp_live;
 assign raw_valid=in_valid && rlive && !frame_abort;
 assign isp_valid=in_valid && ilive && !frame_abort;
 assign raw_data=in_raw,isp_data=in_raw,out_x=in_x,out_y=in_y;
 assign out_sof=in_sof,out_eol=in_eol,out_last=in_last,out_tag=in_tag;
 // 两个支路独立统计；共享输入错误同时作废两支，导出过载不阻断主视频。
 always @(posedge pclk or negedge rst_n)begin
  if(!rst_n)begin
   raw_live<=0;isp_live<=0;raw_counted<=0;isp_counted<=0;
   raw_abort<=0;isp_abort<=0;raw_end<=0;isp_end<=0;raw_legal<=0;isp_legal<=0;
   raw_dropped_frames<=0;isp_dropped_frames<=0;
  end else begin
   raw_abort<=0;isp_abort<=0;raw_end<=frame_end;isp_end<=frame_end;
   raw_legal<=frame_end && frame_legal && rlive && !frame_abort && !(in_valid && !raw_ready);
   isp_legal<=frame_end && frame_legal && ilive && !frame_abort && !(in_valid && !isp_ready);
   if(frame_start)begin
    raw_live<=rlive;isp_live<=ilive;raw_counted<=0;isp_counted<=0;
    if(frame_admitted && !raw_admit)begin
     raw_dropped_frames<=raw_dropped_frames+1'b1;raw_counted<=1;raw_abort<=1;
    end
    if(frame_admitted && !isp_admit)begin
     isp_dropped_frames<=isp_dropped_frames+1'b1;isp_counted<=1;isp_abort<=1;
    end
   end
   if((in_valid && rlive && !raw_ready) || (frame_abort && rlive))begin
    raw_live<=0;raw_abort<=1;
    if(!raw_counted || frame_start)begin raw_dropped_frames<=raw_dropped_frames+1'b1;raw_counted<=1;end
   end
   if((in_valid && ilive && !isp_ready) || (frame_abort && ilive))begin
    isp_live<=0;isp_abort<=1;
    if(!isp_counted || frame_start)begin isp_dropped_frames<=isp_dropped_frames+1'b1;isp_counted<=1;end
   end
   if(frame_end)begin raw_live<=0;isp_live<=0;end
  end
 end
endmodule
