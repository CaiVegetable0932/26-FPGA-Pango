// 模块用途：MINI CAM1 的复位时序、厂商 RGB565 配置表及 DVP 前端封装。
// 修改：SCCB 两线开漏；NACK/超时不推进配置表，必须复位后重新开始。
module camera (
    input   wire            clk             ,
    input   wire            rst_n           ,
    inout   wire            SCL             ,
    inout   wire            SDA             ,
    input   wire            camera_clk      ,
    input   wire    [7:0]   camera_data     ,
    input   wire            camera_herf     ,
    input   wire            camera_vsync    ,
    input   wire            ddr_init        ,
    output  wire            camera_rstn     ,
    output  wire            camera_pwnd     ,
    output  wire            init_done       ,
    output  wire    [15:0]  wf_wr_data      ,   //RGB565
    output  wire            wf_wr_en        ,
    output  wire            vs              ,
    output  wire            hs              ,
    output  wire            sop             ,
    output  wire            eop 
);

wire            sccb_done   ;
wire            sccb_error;
wire            sccb_start  ;
wire [23:0]     data_in     ; 

reg [18:0]cnt1;
reg [15:0]cnt2;
reg [19:0]cnt3;
reg initial_en;
reg camera_rstn_reg;
reg camera_pwnd_reg;

assign camera_rstn=camera_rstn_reg;
assign camera_pwnd=camera_pwnd_reg;

// Purpose: 262144/27MHz = 9.71ms startup hold; module PWDN is physically tied low.
always@(posedge clk or negedge rst_n)begin
    if(!rst_n) begin
    	cnt1 <= 0;
    	camera_pwnd_reg <= 1'b1;// 1'b1 
    end
    else if(cnt1 < 19'h40000) begin
        cnt1 <= cnt1 + 1'b1;
        camera_pwnd_reg <= 1'b1;
    end
    else
        camera_pwnd_reg <= 1'b0;         
end

// Purpose: hold sensor RESETB for another 65535/27MHz = 2.43ms.
always@(posedge clk or negedge rst_n)begin
    if(!rst_n) begin
        cnt2 <= 0;
        camera_rstn_reg <= 1'b0;  
    end
    else if(camera_pwnd_reg == 1)  begin
  	    cnt2 <= 0;
        camera_rstn_reg <= 1'b0;  
    end
    else if(cnt2 < 16'hffff) begin
        cnt2 <= cnt2 + 1'b1;
        camera_rstn_reg <= 1'b0;
    end
    else
        camera_rstn_reg <= 1'b1;         
end

// Purpose: wait 1048575/27MHz = 38.84ms after RESETB release before SCCB.
always@(posedge clk or negedge rst_n)begin
    if(!rst_n) begin
        cnt3 <= 0;
        initial_en <= 1'b0;
    end
    else if(camera_rstn_reg == 0) begin
        cnt3 <= 0;
        initial_en <= 1'b0;
    end
    else if(cnt3 < 20'hfffff) begin
        cnt3 <= cnt3 + 1'b1;
        initial_en <= 1'b0;
    end
    else
        initial_en <= 1'b1;    
end


data_init data_init_inst(
    /*input   wire            */.sys_clk   (clk      ) ,    // 系统时钟
    /*input   wire            */.sys_rst_n (rst_n & initial_en ) ,  // 只有在硬复位时序走完后，才允许开启 I2C 寄存器配置！！
    /*input   wire            */.cfg_end   (sccb_done && !sccb_error) , // 用途：只有真实 ACK 成功才推进配置。
    /*                        */     
    /*output  reg             */.cfg_start (sccb_start) ,  // 单个寄存器配置触发
    /*output  wire    [23:0]  */.cfg_data  (data_in   ) ,   // {REG_ADDR[15:0], REG_VAL[7:0]}
    /*output  reg             */.cfg_done  (init_done )  // 全部配置完成
);

SCCB SCCB_u(
    .clk         (clk         ),   //时钟
    .rst_n       (rst_n       ),   //复位
    .sccb_start  (sccb_start  ),   //开始信号
    .data_in     (data_in     ),   //高位地址 + 低位地址 + 数据
    .SCL         (SCL         ),   //
    .SDA         (SDA         ),   //
    .sccb_done   (sccb_done   ),   // 事务结束，不等同成功。
    .sccb_error  (sccb_error  ),   // NACK 或拉伸超时：配置保持未完成。
    .busy        ()
);

// Purpose: asynchronous assertion and PCLK-synchronous release for the capture domain.
wire capture_reset_n;
reset_sync rs_capture(camera_clk, rst_n, capture_reset_n);
camera_data camera_data_u(
    /*input   wire            */.clk           ( camera_clk      )      ,
    /*input   wire            */.rst_n         ( capture_reset_n )      ,
    /*input   wire            */.vsync         ( camera_vsync    )      ,//表示新一帧到来
    /*input   wire            */.href          ( camera_herf     )      ,//有效信号
    /*input   wire    [7:0]   */.din           ( camera_data     )      ,
    /*input   wire            */.cfg_done      ( init_done       )      ,//摄像头配置完成标准信号
    /*input   wire            */.ddr_init      ( ddr_init & initial_en )      ,
    /*output  reg     [15:0]  */.pixel_data    ( wf_wr_data      )      ,//像素数据rgb565
    /*output  wire            */.wf_wr_en      ( wf_wr_en        )      ,
    /*output  reg             */.vs            ( vs              )      ,
    /*output  reg             */.hs            ( hs              )      ,
    /*output  reg             */.sop           ( sop             )      ,// 帧头
    /*output  reg             */.eop           ( eop             )       //帧尾在最后一行最后一个计数器结束
);			
    
endmodule
