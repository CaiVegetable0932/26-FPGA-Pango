// Purpose: pair OV5640 DVP bytes into RGB565 pixels in the source PCLK domain.
// Re-align at every HREF gap/VSYNC and synchronize configuration/DDR-ready levels.
// Limit: short-line/frame rejection and downstream frame invalidation are not implemented.
module camera_data #(
    parameter FRAME_WIDTH=1280, FRAME_HEIGHT=720, WARMUP_FRAMES=10
) (
    input   wire            clk                 ,
    input   wire            rst_n               ,
    input   wire            vsync               ,//表示新一帧到来
    input   wire            href                ,//有效信号
    input   wire    [7:0]   din                 ,
    input   wire            cfg_done            ,//摄像头配置完成标准信号
    input   wire            ddr_init            ,
    output  reg     [15:0]  pixel_data          ,//像素数据rgb565
    output  wire            wf_wr_en            ,
    output  reg             sop                 ,// 帧头
    output  reg             eop                 ,//帧尾在最后一行最后一个计数器结束
    output  reg             vs                  ,
    output  reg             hs                  
);								 
//---------<参数定义>------------------------------------------------
    
//---------<内部信号定义>--------------------------------------------
reg             flag          ;
reg     [2:0]   vsync_r       ;//打三拍下降沿检测
wire            vsync_negedge ;
//  行场计数器 
reg		[11:0]	cnt_h	   ;//2560
wire			add_cnt_h;
wire			end_cnt_h;
reg		[9:0]	cnt_v	   ;//720
wire			add_cnt_v;
wire			end_cnt_v;

// 用途：就绪掉线时重新丢弃过渡帧，参数宽度可容纳任意非负预热帧数。
localparam WARMUP_BITS=(WARMUP_FRAMES<1) ? 1 : $clog2(WARMUP_FRAMES+1);
reg [WARMUP_BITS-1:0] eop_cnt;
wire            pic_valid;

reg             pixel_data_vld;
// Purpose: only these readiness levels cross clock domains; DVP data/VSYNC/HREF
// are sampled together using their source-synchronous PCLK, not separate 2FF chains.
(* syn_preserve = 1 *) reg cfg_meta, cfg_sync, ddr_meta, ddr_sync;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin cfg_meta<=0; cfg_sync<=0; ddr_meta<=0; ddr_sync<=0; end
    else begin cfg_meta<=cfg_done; cfg_sync<=cfg_meta; ddr_meta<=ddr_init; ddr_sync<=ddr_meta; end


// Purpose: discard complete-counted startup frames only after configuration and DDR readiness.
always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)
        eop_cnt <= 0;
    else if(!cfg_sync || !ddr_sync) eop_cnt <= 0;
    else if(eop_cnt == WARMUP_FRAMES)
        eop_cnt <= eop_cnt;
    else if(eop)
        eop_cnt <= eop_cnt + 1;
end
assign pic_valid = (eop_cnt == WARMUP_FRAMES);

assign wf_wr_en = (pic_valid && cfg_sync && ddr_sync) ? pixel_data_vld : 0;

//下降沿检测
always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        vsync_r <= 3'b111;
    end 
    else begin 
        vsync_r <= {vsync_r[1:0],vsync};
    end 
end
assign  vsync_negedge = ~vsync_r[1] & vsync_r[2];

always @(posedge clk or negedge rst_n)begin 
   if(!rst_n)begin
        cnt_h <= 'd0;
    end 
    // Purpose: discard a dangling first byte at line/frame boundaries.
    else if (!href || vsync || (!cfg_sync || !ddr_sync)) cnt_h <= 0;
    else if(add_cnt_h)begin
        if(end_cnt_h)begin 
            cnt_h <= 'd0;
        end
        else begin 
            cnt_h <= cnt_h + 1'b1;
        end 
    end
end 

assign add_cnt_h = href && flag;
assign end_cnt_h = add_cnt_h && cnt_h == FRAME_WIDTH*2-1;


always @(posedge clk or negedge rst_n)begin 
   if(!rst_n)begin
        cnt_v <= 'd0;
    end 
    // Purpose: never carry a partial frame's row count into the next frame.
    else if (vsync || (!cfg_sync || !ddr_sync)) cnt_v <= 0;
    else if(add_cnt_v)begin
        if(end_cnt_v)begin 
            cnt_v <= 'd0;
        end
        else begin 
            cnt_v <= cnt_v + 1'b1;
        end 
    end
end

assign add_cnt_v = end_cnt_h ;
assign end_cnt_v = add_cnt_v && cnt_v == FRAME_HEIGHT-1;


always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        flag <= 'd0;
    end 
    else if (vsync || (!cfg_sync || !ddr_sync)) flag <= 0;
    else if(vsync_negedge && cfg_sync && ddr_sync)begin
        flag <= 1;
    end 
    else if(end_cnt_v)begin
        flag <= 0;
    end
end    
//输出
always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        pixel_data <= 'd0;
    end 
    else if(pic_valid) begin 
        pixel_data <= {pixel_data[7:0],din};
    end 
end

always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        pixel_data_vld <= 'd0;
        sop <= 0;
        eop <= 0;
        vs  <= 0;
        hs  <= 0;
    end 
    else begin 
        pixel_data_vld <=  add_cnt_h && cnt_h[0];//行计数器为奇数时有效
        sop <= add_cnt_h && cnt_v==0 && cnt_h==1;
        eop <= end_cnt_v;
        // 只有过了前十帧（pic_valid为高），才向后级输出对齐的vsync和href
        vs  <= (pic_valid && cfg_sync && ddr_sync) ? vsync : 1'b0;
        hs  <= (pic_valid && cfg_sync && ddr_sync) ? href  : 1'b0;
    end 
end

endmodule
