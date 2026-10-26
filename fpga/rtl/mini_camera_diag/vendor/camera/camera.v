// 模块用途：MINI CAM1 的复位时序、厂商 RGB565 配置表及 DVP 前端封装。
// 修改：初始化独占 SCCB，随后进行身份/参数回读；固定组验证成功才开放采集。
module camera #(
    parameter FIXED_MODE=0,
    parameter [19:0] EXPOSURE=0,
    parameter [9:0] GAIN=10'h010,
    parameter [11:0] WB_R=12'h400, WB_G=12'h400, WB_B=12'h400,
    parameter [15:0] EXPECT_HTS=0, EXPECT_VTS=0,
    parameter VTS_MARGIN=4,
    // 用途：默认保持现有 27MHz 板级延时，仿真可缩短；不改变摄像头 XCLK。
    parameter CTRL_CLK_HZ=27000000, SCCB_CLK_HZ=100000,
    parameter POWERUP_CYCLES=262144, RESET_CYCLES=65535, SCCB_DELAY_CYCLES=1048575,
    parameter WRITE_WAIT_CYCLES=27000, RESET_WAIT_CYCLES=135000
) (
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
    output  wire            eop,
    // 用途：控制时钟域的有界查询和逐寄存器回读证据，不分配 UART 报文。
    input wire query_start, input wire [15:0] query_addr,
    output wire query_ready, query_done, query_rejected,
    output wire [7:0] query_value, output wire [2:0] query_status,
    output wire [31:0] config_version,
    output wire [2:0] config_fault, output wire [15:0] fault_addr,
    output wire snapshot_valid, output wire [15:0] snapshot_addr,
    output wire [7:0] snapshot_value, output wire [31:0] snapshot_cycle,
    output wire [31:0] row_ticks, frame_ticks, source_frames,
    output wire row_valid, frame_valid
);

wire            sccb_done   ;
wire sccb_error, table_done, control_start, control_read;
wire [23:0] control_data;
wire [7:0] read_value;
wire [1:0] tx_error;
wire [2:0] control_fault;
wire [15:0] control_fault_addr;
reg init_failed;
// 用途：初始化失败立即锁存，禁止服务取得总线所有权；复位才能重试。
always @(posedge clk or negedge rst_n)
    if(!rst_n) init_failed<=0;
    else if(!table_done && sccb_done && sccb_error) init_failed<=1;
assign config_fault=init_failed ? {1'b0,tx_error} : control_fault;
assign fault_addr=init_failed ? data_in[23:8] : control_fault_addr;
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
    else if(cnt1 < POWERUP_CYCLES) begin
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
    else if(cnt2 < RESET_CYCLES) begin
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
    else if(cnt3 < SCCB_DELAY_CYCLES) begin
        cnt3 <= cnt3 + 1'b1;
        initial_en <= 1'b0;
    end
    else
        initial_en <= 1'b1;    
end


data_init #(.CNT_WAIT_MAX(WRITE_WAIT_CYCLES),.RESET_WAIT_MAX(RESET_WAIT_CYCLES)) data_init_inst(
    /*input   wire            */.sys_clk   (clk      ) ,    // 系统时钟
    /*input   wire            */.sys_rst_n (rst_n & initial_en ) ,  // 只有在硬复位时序走完后，才允许开启 I2C 寄存器配置！！
    /*input   wire            */.cfg_end   (sccb_done && !sccb_error) , // 用途：只有真实 ACK 成功才推进配置。
    /*                        */     
    /*output  reg             */.cfg_start (sccb_start) ,  // 单个寄存器配置触发
    /*output  wire    [23:0]  */.cfg_data  (data_in   ) ,   // {REG_ADDR[15:0], REG_VAL[7:0]}
    /*output  reg             */.cfg_done  (table_done )  // 全部配置完成
);

// 用途：初始化和查询控制器互斥复用同一个开漏主机，绝不双重驱动。
ov5640_control #(.FIXED_MODE(FIXED_MODE),.EXPOSURE(EXPOSURE),.GAIN(GAIN),
    .WB_R(WB_R),.WB_G(WB_G),.WB_B(WB_B),
    .EXPECT_HTS(EXPECT_HTS),.EXPECT_VTS(EXPECT_VTS),.VTS_MARGIN(VTS_MARGIN)) control(
    .clk(clk),.rst_n(rst_n),.table_done(table_done && !init_failed),
    .tx_start(control_start),.tx_read(control_read),.tx_data(control_data),
    .tx_done(sccb_done),.tx_error(tx_error),.tx_value(read_value),
    .query_start(query_start),.query_addr(query_addr),.query_ready(query_ready),
    .query_done(query_done),.query_rejected(query_rejected),
    .query_value(query_value),.query_status(query_status),
    .capture_ready(init_done),.config_version(config_version),
    .fault(control_fault),.fault_addr(control_fault_addr),
    .snapshot_valid(snapshot_valid),.snapshot_addr(snapshot_addr),
    .snapshot_value(snapshot_value),.snapshot_cycle(snapshot_cycle));
SCCB #(.SYS_CLK(CTRL_CLK_HZ),.SCCB_CLK(SCCB_CLK_HZ)) SCCB_u(
    .clk         (clk         ),   //时钟
    .rst_n       (rst_n       ),   //复位
    .sccb_start  (table_done ? control_start : sccb_start),   //开始信号
    .data_in     (table_done ? control_data : data_in),   //高位地址 + 低位地址 + 数据
    .sccb_read   (table_done && control_read),
    .read_data   (read_value), .error_code(tx_error),
    .SCL         (SCL         ),   //
    .SDA         (SDA         ),   //
    .sccb_done   (sccb_done   ),   // 事务结束，不等同成功。
    .sccb_error  (sccb_error  ),   // NACK 或拉伸超时：配置保持未完成。
    .busy        ()
);

// 用途：独立记录传感器节拍，不把 HDMI 输出帧率当成摄像头源帧率。
ov5640_timing_monitor timing_monitor(.clk(clk),.rst_n(rst_n),
    .href(camera_herf),.vsync(camera_vsync),.row_ticks(row_ticks),
    .frame_ticks(frame_ticks),.source_frames(source_frames),
    .row_valid(row_valid),.frame_valid(frame_valid));
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
