// 用途：在控制时钟域测 HREF 起点/VSYNC 起点间隔，提供源节拍观察。
// 双级同步量化带来约数个控制周期误差；HREF 间隔需结合裁剪/抽样核对内部行。
// 不以这些边沿计数断言帧完整、像素尺寸、光学频率或 HDMI 来源身份。
module ov5640_timing_monitor(
    input wire clk,rst_n,href,vsync,
    output reg [31:0] row_ticks,frame_ticks,source_frames,
    output reg row_valid,frame_valid
);
    (* syn_preserve=1 *) reg hmeta,hsync,vmeta,vsync_sync;
    reg hprev,vprev,row_seen,frame_seen;
    reg [31:0] ticks,row_start,frame_start;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            hmeta<=0;hsync<=0;vmeta<=0;vsync_sync<=0;hprev<=0;vprev<=0;
            row_seen<=0;frame_seen<=0;ticks<=0;row_start<=0;frame_start<=0;
            row_ticks<=0;frame_ticks<=0;source_frames<=0;row_valid<=0;frame_valid<=0;
        end else begin
            hmeta<=href;hsync<=hmeta;vmeta<=vsync;vsync_sync<=vmeta;
            hprev<=hsync;vprev<=vsync_sync;ticks<=ticks+1'b1;
            if(vsync_sync)row_seen<=0;
            if(vsync_sync && !vprev)begin
                if(frame_seen)begin frame_ticks<=ticks-frame_start;frame_valid<=1;end
                frame_start<=ticks;frame_seen<=1;source_frames<=source_frames+1'b1;
            end
            if(hsync && !hprev && !vsync_sync)begin
                if(row_seen)begin row_ticks<=ticks-row_start;row_valid<=1;end
                row_start<=ticks;row_seen<=1;
            end
        end
    end
endmodule
