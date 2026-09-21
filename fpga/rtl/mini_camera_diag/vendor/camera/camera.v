// 模块用途：MINI CAM1 经身份及配置回读验证后，才使能 RGB565 DVP 采集。
// 修改：启动由 ov5640_startup 管理，最多三次尝试；未验证成功时禁止写入帧池。
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
    output  wire            eop,
    // Purpose: forward capture-domain gates/events for on-board fault isolation.
    output  wire [7:0]      capture_status
);

// Purpose: explicit hardware reset, chip identification, standby configuration,
// stream-on and critical register readback. PWDN on this module is tied low.
assign camera_pwnd = 1'b0;
ov5640_startup startup(
    .clk(clk),.rst_n(rst_n),.scl(SCL),.sda(SDA),
    .reset_n(camera_rstn),.ready(init_done),.failed(),
    .error_code(),.verify_index(),.last_read());
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
    /*input   wire            */.ddr_init      ( ddr_init )      ,
    /*output  reg     [15:0]  */.pixel_data    ( wf_wr_data      )      ,//像素数据rgb565
    /*output  wire            */.wf_wr_en      ( wf_wr_en        )      ,
    /*output  reg             */.vs            ( vs              )      ,
    /*output  reg             */.hs            ( hs              )      ,
    /*output  reg             */.sop           ( sop             )      ,// 帧头
    /*output  reg             */.eop           ( eop             ),      //帧尾在最后一行最后一个计数器结束
    .capture_status(capture_status)
);

endmodule
