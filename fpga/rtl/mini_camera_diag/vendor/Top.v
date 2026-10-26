`timescale 1ns / 1ps
// Purpose: single-CAM1 720p RGB565 diagnostic adaptation of the MINI 200H demo.
// PG2L100H-6FBG676 only; no RAW8/PRAW network path. NOT RELEASED FOR DOWNLOAD:
// frame ownership, FIFO fault recovery and external timing still need validation.
module Top#(
	parameter MEM_ROW_ADDR_WIDTH   = 15         ,
	parameter MEM_COL_ADDR_WIDTH   = 10         ,
	parameter MEM_BADDR_WIDTH      = 3          ,
	parameter MEM_DQ_WIDTH         =  32        ,
	// 用途：固定测评只在复位后的首次采集前提交；曝光必须由核验输入计算。
    parameter CAMERA_FIXED_MODE=0,
    parameter [19:0] CAMERA_EXPOSURE=0,
    parameter [9:0] CAMERA_GAIN=10'h010,
    parameter [11:0] CAMERA_WB_R=12'h400, CAMERA_WB_G=12'h400, CAMERA_WB_B=12'h400,
    parameter [15:0] CAMERA_EXPECT_HTS=0, CAMERA_EXPECT_VTS=0,
    parameter CAMERA_VTS_MARGIN=4,
	parameter MEM_DQS_WIDTH        =  32/8
)(
	input   wire                                sys_clk        ,//27Mhz
    input   wire                                clk_p          ,
    input   wire                                clk_n          ,
    input   wire                                rst_in         ,
    //DDR
    output  wire                                mem_rst_n      ,
    output  wire                                mem_ck         ,
    output  wire                                mem_ck_n       ,
    output  wire                                mem_cke        ,
    output  wire                                mem_cs_n       ,
    output  wire                                mem_ras_n      ,
    output  wire                                mem_cas_n      ,
    output  wire                                mem_we_n       ,
    output  wire                                mem_odt        ,
    output  wire    [MEM_ROW_ADDR_WIDTH-1:0]    mem_a          ,
    output  wire    [MEM_BADDR_WIDTH-1:0]       mem_ba         ,
    inout   wire    [MEM_DQ_WIDTH/8-1:0]        mem_dqs        ,
    inout   wire    [MEM_DQ_WIDTH/8-1:0]        mem_dqs_n      ,
    inout   wire    [MEM_DQ_WIDTH-1:0]          mem_dq         ,
    output  wire    [MEM_DQ_WIDTH/8-1:0]        mem_dm         ,
    output  reg                                 heart_beat_led ,
    //cam
    input   wire                                camera_clk_0   ,
    input   wire    [7:0]                       camera_data_0  ,
    input   wire                                camera_href_0  ,
    input   wire                                camera_vsync_0 ,
    inout   wire                                SCL_0          ,
    inout   wire                                SDA_0          ,
    output  wire                                cam_rst_0      ,
    //hdmi                                                            
    output  wire    [2:0]                       tmds_data_p    ,
    output  wire    [2:0]                       tmds_data_n    ,
    output  wire                                tmds_clk_p     ,
    output  wire                                tmds_clk_n     ,

    output  reg                                 cam_led0       ,
    output  reg                                 cam_led1       
);
//=====================================================================================
//reg define
//=====================================================================================
// ENABLE_DDR
localparam CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;//28
// Purpose: one second of the native 125 MHz DDR user clock.
localparam TH_1S = 27'd124999999;
wire  ddr_init_done;
// No undeclared LCD enable net: this diagnostic has TMDS output only.
//=====================================================================================
//clk
//=====================================================================================
wire    pclk;
wire    pclkx5;
wire    serial_raw;
wire    locked0;
wire    rst_n;

// Purpose: reproduce the PG2L100H native high-speed-output topology: the PLL
// supplies one 371.25 MHz source, GTP_IOCLKBUF drives the OSERDES I/O clock and
// GTP_IOCLKDIV_E2 derives the phase-related 74.25 MHz pixel clock. A delayed
// divider reset follows the official example so the /5 phase starts cleanly.
wire video_div_reset_n;
wire video_clock_ready;
wire pixel_reset_n, cam_reset_n, mem_reset_n;
video_pll u_video_pll(.clkin1(sys_clk), .clkout1(serial_raw), .lock(locked0));
GTP_IOCLKBUF u_hdmi_serial_clock(.CLKIN(serial_raw), .DI(1'b1), .CLKOUT(pclkx5));
GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_hdmi_pixel_clock(
 .CE(1'b1), .CLKIN(serial_raw), .RST_N(video_div_reset_n), .CLKDIVOUT(pclk));
// Purpose: keep the native startup pulse, but assert pixel reset immediately
// on unlock even with pclk stopped. Ready crosses only the first pixel stage;
// reference control and pixel consumers each release in their own domain.
video_clock_start u_video_start(.ref_clk(sys_clk), .pixel_clk(pclk),
 .async_reset_n(rst_in && locked0), .reference_reset_n(rst_n),
 .divider_reset_n(video_div_reset_n), .clock_ready(video_clock_ready), .pixel_reset_n(pixel_reset_n));
reset_sync rs_camera(camera_clk_0, rst_in && locked0, cam_reset_n);
// DDR user logic also resets on controller/PHY unlock; controller reset itself
// remains external-only so user readiness cannot prevent calibration startup.
reset_sync rs_mem(core_clk, rst_in && pll_lock && phy_pll_lock && ddr_init_done, mem_reset_n);

//===========================================================================
// camera
//===========================================================================
wire            cam_vsync_0;
wire            cam_href_0;
wire            cam_write_en_0;
wire    [15:0]  cam_data_0;

wire            cam_vsync_1;
wire            cam_href_1;
wire            cam_write_en_1;
wire    [15:0]  cam_data_1;

wire            cam_init_done_0;
wire            cam_init_done_1;

camera #(.FIXED_MODE(CAMERA_FIXED_MODE),.EXPOSURE(CAMERA_EXPOSURE),
    .GAIN(CAMERA_GAIN),.WB_R(CAMERA_WB_R),.WB_G(CAMERA_WB_G),.WB_B(CAMERA_WB_B),
    .EXPECT_HTS(CAMERA_EXPECT_HTS),.EXPECT_VTS(CAMERA_EXPECT_VTS),
    .VTS_MARGIN(CAMERA_VTS_MARGIN)) camera_inst0(
    // 用途：此顶层尚无 PC 查询桥，明确禁用外部请求；查询端口供后续集成。
    .query_start(1'b0),.query_addr(16'b0),
    .query_ready(),.query_done(),.query_rejected(),.query_value(),.query_status(),
    .config_version(),.config_fault(),.fault_addr(),.snapshot_valid(),
    .snapshot_addr(),.snapshot_value(),.snapshot_cycle(),
    .row_ticks(),.frame_ticks(),.source_frames(),.row_valid(),.frame_valid(),
    /*input   wire            */.clk           ( sys_clk             )  ,
    /*input   wire            */.rst_n         ( rst_n               )  ,
    /*output  wire            */.SCL           ( SCL_0               )  ,  
    /*output  wire            */.SDA           ( SDA_0               )  ,  
    /*input   wire            */.camera_clk    ( camera_clk_0        )  ,
    /*input   wire    [7:0]   */.camera_data   ( camera_data_0       )  ,
    /*input   wire            */.camera_herf   ( camera_href_0       )  ,
    /*input   wire            */.camera_vsync  ( camera_vsync_0      )  ,
    /*input   wire            */.ddr_init      ( ddr_init_done       )  ,
    /*output  wire            */.camera_rstn   ( cam_rst_0           )  ,
    /*output  wire            */.camera_pwnd   ()  ,
    /*output  wire            */.init_done     ( cam_init_done_0     )  ,
    /*output  wire    [15:0]  */.wf_wr_data    ( cam_data_0          )  ,   //RGB565
    /*output  wire            */.wf_wr_en      ( cam_write_en_0      )  ,
    /*output  wire            */.vs            ( cam_vsync_0         )  ,
    /*output  wire            */.hs            ( cam_href_0          )  ,
    /*output  wire            */.sop           ()  ,
    /*output  wire            */.eop           ()  
);

// Purpose: CAM1 LED indicates PCLK activity only, not video validity or FPS.
reg [24:0] cam_cnt_0;
always @(posedge camera_clk_0 or negedge cam_reset_n) begin
 if (!cam_reset_n) begin cam_cnt_0 <= 0; cam_led0 <= 1; end
 else if (cam_cnt_0 == 25'd23999999) begin cam_cnt_0 <= 0; cam_led0 <= ~cam_led0; end
 else cam_cnt_0 <= cam_cnt_0 + 1'b1;
end
// Purpose: active-low LED indicates initialization plus ID/readback checks; not optical validation.
always @(posedge sys_clk or negedge rst_n)
 if (!rst_n) cam_led1 <= 1'b1; else cam_led1 <= !cam_init_done_0;
//video_scale
//=====================================================================================
wire    [15:0]    write_data_0;
wire              write_en_0;

wire    [15:0]    write_data_1;
wire              write_en_1;

// Purpose: preserve all 1280 pixels; bypass the vendor VSYNC-clocked scaler.
assign write_data_0 = cam_data_0;
assign write_en_0 = cam_write_en_0;
wire write_req_0;
wire                            write_req_ack_0;
wire[1:0]                       write_addr_index_0;
wire[1:0]                       read_addr_index_0;

wire                            write_req_1;
wire                            write_req_ack_1;
wire[1:0]                       write_addr_index_1;
wire[1:0]                       read_addr_index_1;

cmos_write_req_gen cmos_write_req_gen_inst0(
	.rst                        ( ~cam_reset_n       ), // Release in capture clock domain.
	.pclk                       ( camera_clk_0       ),
	.cmos_vsync                 ( cam_vsync_0        ),
	.write_req                  ( write_req_0        ),
	.write_addr_index           (), // Slot indices are owned by the memory-domain pool.
	.read_addr_index            (),
	.write_req_ack              ( write_req_ack_0    )
);

// CAM2 request generator intentionally absent.

//=====================================================================================
//产生visa时序 
//=====================================================================================
localparam X_WIDTH   = 4'd12;
localparam Y_WIDTH   = 4'd12;
localparam  X_BITS   = 4'd13   ;
localparam  Y_BITS   = 4'd13   ;
localparam  V_TOTAL  = 12'd750 ;
localparam  V_FP     = 12'd5   ;
localparam  V_BP     = 12'd20  ;
localparam  V_SYNC   = 12'd5   ;
localparam  V_ACT    = 12'd720 ;
localparam  H_TOTAL  = 12'd1650;
localparam  H_FP     = 12'd110 ;
localparam  H_BP     = 12'd220 ;
localparam  H_SYNC   = 12'd40  ;
localparam  H_ACT    = 12'd1280;

wire            read_req_0;
wire            read_req_ack_0;
wire            read_en_0;
wire    [15:0]  read_data_0;
    
wire            read_req_1;
wire            read_req_ack_1;
wire            read_en_1;
wire    [15:0]  read_data_1;

wire            vs_out_sync;
wire            hs_out_sync;
wire            de_out_sync;

wire            vs_out_0;
wire            hs_out_0;
wire            de_out_0;

wire            vs_out_1;
wire            hs_out_1;
wire            de_out_1;

wire    [15:0]  vout_data_0;
wire    [15:0]  vout_data_1;

sync_vg #(
    .X_BITS               ( X_WIDTH ), 
    .Y_BITS               ( Y_WIDTH ),
    .V_TOTAL              ( V_TOTAL ),
    .V_FP                 ( V_FP    ),
    .V_BP                 ( V_BP    ),
    .V_SYNC               ( V_SYNC  ),
    .V_ACT                ( V_ACT   ),
    .H_TOTAL              ( H_TOTAL ),
    .H_FP                 ( H_FP    ),
    .H_BP                 ( H_BP    ),
    .H_SYNC               ( H_SYNC  ),
    .H_ACT                ( H_ACT   )
) sync_vg_inst (                                                 
    .clk                  ( pclk        ),
    .rstn                 ( pixel_reset_n ), // Release in display clock domain.
    .vs_out               ( vs_out_sync ),
    .hs_out               ( hs_out_sync ),
    .de_out               ( de_out_sync ),
    .x_act                (),            
    .y_act                ()             
); 


video_rect_read_data video_rect_read_data_inst0(
	.video_clk                  ( pclk           ),
	.rst                        ( ~pixel_reset_n ), // Reset all display pipeline stages.
	.video_left_offset          ( 0              ),
	.video_top_offset           ( 0              ),
	.video_width                ( 12'd1280 ),
	.video_height	            ( 720            ),
	.read_req                   ( read_req_0     ),
	.read_req_ack               ( read_req_ack_0 ),
	.read_en                    ( read_en_0      ),
	.read_data                  ( read_data_0    ),
	.timing_hs                  ( hs_out_sync    ),
	.timing_vs                  ( vs_out_sync    ),
	.timing_de                  ( de_out_sync    ),
	.timing_data 	            ( 0              ),
	.hs                         ( hs_out_0       ),
	.vs                         ( vs_out_0       ),
	.de                         ( de_out_0       ),
	.vout_data                  ( vout_data_0    )
);

// CAM2 compositor intentionally absent; CAM1 fills the raster.

//===========================================================================
// 视频输出
//===========================================================================
wire            hs_out   ;
wire            vs_out   ;
wire            de_out   ;
wire    [23:0]  vout_data;

// Purpose: output the full CAM1 frame, expanding RGB565 into RGB888.
assign hs_out=hs_out_0;
assign vs_out=vs_out_0;
assign de_out=de_out_0;
// Purpose: do not expose unwritten DDR contents before a complete frame is published.
assign vout_data=display_valid_sync ?
 {vout_data_0[15:11],3'b0,vout_data_0[10:5],2'b0,vout_data_0[4:0],3'b0} : 24'b0;

rgb2tmds rgb2tmds_inst (
    /*output  wire            */.tmds_clk_p  ( tmds_clk_p   ) ,
    /*output  wire            */.tmds_clk_n  ( tmds_clk_n   ) ,
    /*output  wire    [2:0]   */.tmds_data_p ( tmds_data_p  ) ,
    /*output  wire    [2:0]   */.tmds_data_n ( tmds_data_n  ) ,

    /*input   wire            */.rstn        ( pixel_reset_n ) , // Pixel encoder/display reset domain.
    /*input   wire            */.serializer_rstn ( video_div_reset_n ) , // Native GTP startup pulse.

    /*input   wire    [23:0]  */.vid_pdata   ( vout_data    ) ,
    /*input   wire            */.vid_pvde    ( de_out       ) ,
    /*input   wire            */.vid_phsync  ( hs_out       ) ,
    /*input   wire            */.vid_pvsync  ( vs_out       ) ,
 
    /*input   wire            */.pixelclk    ( pclk         ) ,
    /*input   wire            */.serialclk   ( pclkx5       )
);

//=====================================================================================
//ddr读写模块
//=====================================================================================
localparam MEM_DATA_BITS          = 256;             //external memory user interface data width
localparam ADDR_BITS              = 25;             //external memory user interface address width
localparam BUSRT_BITS             = 10;             //external memory user interface burst width

wire                            wr_burst_req;
wire[BUSRT_BITS - 1:0]          wr_burst_len;
wire[ADDR_BITS - 1:0]           wr_burst_addr;
wire                            wr_burst_data_req;
wire[MEM_DATA_BITS - 1 : 0]     wr_burst_data;
wire                            wr_burst_finish;

wire                            rd_burst_req;
wire[BUSRT_BITS - 1:0]          rd_burst_len;
wire[ADDR_BITS - 1:0]           rd_burst_addr;
wire                            rd_burst_data_valid;
wire[MEM_DATA_BITS - 1 : 0]     rd_burst_data;
wire                            rd_burst_finish;


wire                            wr_burst_req_0;
wire[BUSRT_BITS - 1:0]          wr_burst_len_0;
wire[ADDR_BITS - 1:0]           wr_burst_addr_0;
wire                            wr_burst_data_req_0;
wire[MEM_DATA_BITS - 1 : 0]     wr_burst_data_0;
wire                            wr_burst_finish_0;

wire                            rd_burst_req_0;
wire[BUSRT_BITS - 1:0]          rd_burst_len_0;
wire[ADDR_BITS - 1:0]           rd_burst_addr_0;
wire                            rd_burst_data_valid_0;
wire[MEM_DATA_BITS - 1 : 0]     rd_burst_data_0;
wire                            rd_burst_finish_0;

wire                            wr_burst_req_1;
wire[BUSRT_BITS - 1:0]          wr_burst_len_1;
wire[ADDR_BITS - 1:0]           wr_burst_addr_1;
wire                            wr_burst_data_req_1;
wire[MEM_DATA_BITS - 1 : 0]     wr_burst_data_1;
wire                            wr_burst_finish_1;

wire                            rd_burst_req_1;
wire[BUSRT_BITS - 1:0]          rd_burst_len_1;
wire[ADDR_BITS - 1:0]           rd_burst_addr_1;
wire                            rd_burst_data_valid_1;
wire[MEM_DATA_BITS - 1 : 0]     rd_burst_data_1;
wire                            rd_burst_finish_1;

wire core_clk;
// Purpose: keep in-flight capture, latest completed and displayed slots distinct.
wire pool_write_req,pool_read_req,dma_write_ack,dma_read_ack,dma_write_finish;
wire pool_display_valid;
mini_frame_pool u_frame_pool(.clk(core_clk),.reset_n(mem_reset_n),
 .camera_req(write_req_0),.display_req(read_req_0),.camera_ack(write_req_ack_0),
 .display_ack(read_req_ack_0),.dma_write_ack(dma_write_ack),.dma_read_ack(dma_read_ack),
 .dma_write_finish(dma_write_finish),.dma_write_req(pool_write_req),.dma_read_req(pool_read_req),
 .write_index(write_addr_index_0),.read_index(read_addr_index_0),
 .display_valid(pool_display_valid),.completed_frames(),.abandoned_frames());
(* syn_preserve=1 *) reg display_valid_meta,display_valid_sync;
always @(posedge pclk or negedge pixel_reset_n)
 if(!pixel_reset_n) begin display_valid_meta<=0;display_valid_sync<=0;end
 else begin display_valid_meta<=pool_display_valid;display_valid_sync<=display_valid_meta;end
// Purpose: 1280*720*2/32=57600 DDR words per frame; four 2 MiB slots.

frame_read_write #(
	.MEM_DATA_BITS              (256                      ),
	.READ_DATA_BITS             (16                       ),
	.WRITE_DATA_BITS            (16                       ),
	.ADDR_BITS                  (25                       ),
	.BUSRT_BITS                 (10                       ),
	.BURST_SIZE                 (16                       ) //?
) frame_read_write_inst0(
	.rst                        (~mem_reset_n         ),
	.mem_clk                    (core_clk              ),
	.rd_burst_req               (rd_burst_req_0        ),
	.rd_burst_len               (rd_burst_len_0        ),
	.rd_burst_addr              (rd_burst_addr_0       ),
	.rd_burst_data_valid        (rd_burst_data_valid_0 ),
	.rd_burst_data              (rd_burst_data_0       ),
	.rd_burst_finish            (rd_burst_finish_0     ),
	.read_clk                   (pclk                  ),
	.read_req                   (pool_read_req         ),
	.read_req_ack               (dma_read_ack          ),
	.read_finish                (                      ),
	.read_addr_0                (25'd0                 ), //The first frame address is 0
	.read_addr_1                (25'd65536           ), // 2 MiB slot stride in 32-byte words.
	.read_addr_2                (25'd131072           ),
	.read_addr_3                (25'd196608           ),
	.read_addr_index            (read_addr_index_0     ),
	.read_len                   (25'd57600            ),//frame size 
	.read_en                    (read_en_0 && display_valid_sync),
	.read_data                  (read_data_0           ),

	.wr_burst_req               (wr_burst_req_0        ),
	.wr_burst_len               (wr_burst_len_0        ),
	.wr_burst_addr              (wr_burst_addr_0       ),
	.wr_burst_data_req          (wr_burst_data_req_0   ),
	.wr_burst_data              (wr_burst_data_0       ),
	.wr_burst_finish            (wr_burst_finish_0     ),
	.write_clk                  (camera_clk_0          ),
	.write_req                  (pool_write_req        ),
	.write_req_ack              (dma_write_ack         ),
	.write_finish               (dma_write_finish      ),
	.write_addr_0               (25'd0                 ),
	.write_addr_1               (25'd65536           ),
	.write_addr_2               (25'd131072           ),
	.write_addr_3               (25'd196608           ),
	.write_addr_index           (write_addr_index_0    ),
	.write_len                  (25'd57600            ), //frame size  
	.write_en                   (write_en_0            ),
	.write_data                 (write_data_0          )
);
// Purpose: keep unused arbiter channel idle; no CAM2 pins or buffers are enabled.
assign rd_burst_req_1=1'b0, wr_burst_req_1=1'b0;
assign rd_burst_len_1=10'b0, wr_burst_len_1=10'b0;
assign rd_burst_addr_1=25'b0, wr_burst_addr_1=25'b0;
assign wr_burst_data_1=256'b0;    

/************************************************************
通道仲裁模块
************************************************************/ 
//读仲裁
mem_read_arbi #(
	.MEM_DATA_BITS               (MEM_DATA_BITS),
	.ADDR_BITS                   (ADDR_BITS    ),
	.BUSRT_BITS                  (BUSRT_BITS   )
)mem_read_arbi_inst(
	.rst_n                        (mem_reset_n), // DDR-domain reset release.
	.mem_clk                      (core_clk),
	.ch0_rd_burst_req             (rd_burst_req_0),
	.ch0_rd_burst_len             (rd_burst_len_0),
	.ch0_rd_burst_addr            (rd_burst_addr_0),
	.ch0_rd_burst_data_valid      (rd_burst_data_valid_0),
	.ch0_rd_burst_data            (rd_burst_data_0),
	.ch0_rd_burst_finish          (rd_burst_finish_0),
	
	.ch1_rd_burst_req             (rd_burst_req_1),
	.ch1_rd_burst_len             (rd_burst_len_1),
	.ch1_rd_burst_addr            (rd_burst_addr_1),
	.ch1_rd_burst_data_valid      (rd_burst_data_valid_1),
	.ch1_rd_burst_data            (rd_burst_data_1),
	.ch1_rd_burst_finish          (rd_burst_finish_1),
	
	.rd_burst_req                 (rd_burst_req),
	.rd_burst_len                 (rd_burst_len),
	.rd_burst_addr                (rd_burst_addr),
	.rd_burst_data_valid          (rd_burst_data_valid),
	.rd_burst_data                (rd_burst_data),
	.rd_burst_finish              (rd_burst_finish)	
);
//写仲裁
mem_write_arbi #(
	.MEM_DATA_BITS               (MEM_DATA_BITS),
	.ADDR_BITS                   (ADDR_BITS    ),
	.BUSRT_BITS                  (BUSRT_BITS   )
)mem_write_arbi_inst(
	.rst_n                       (mem_reset_n), // DDR-domain reset release.
	.mem_clk                     (core_clk),
	
	.ch0_wr_burst_req            (wr_burst_req_0),
	.ch0_wr_burst_len            (wr_burst_len_0),
	.ch0_wr_burst_addr           (wr_burst_addr_0),
	.ch0_wr_burst_data_req       (wr_burst_data_req_0),
	.ch0_wr_burst_data           (wr_burst_data_0),
	.ch0_wr_burst_finish         (wr_burst_finish_0),
	
	.ch1_wr_burst_req            (wr_burst_req_1),
	.ch1_wr_burst_len            (wr_burst_len_1),
	.ch1_wr_burst_addr           (wr_burst_addr_1),
	.ch1_wr_burst_data_req       (wr_burst_data_req_1),
	.ch1_wr_burst_data           (wr_burst_data_1),
	.ch1_wr_burst_finish         (wr_burst_finish_1),

	.wr_burst_req(wr_burst_req),
	.wr_burst_len(wr_burst_len),
	.wr_burst_addr(wr_burst_addr),
	.wr_burst_data_req(wr_burst_data_req),
	.wr_burst_data(wr_burst_data),
	.wr_burst_finish(wr_burst_finish)	
);


wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr      ;
wire [3:0]                  axi_awid        ;
wire [3:0]                  axi_awlen       ;
wire                        axi_awready     ;
wire                        axi_awvalid     ;

wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata       ;
wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb       ;
wire                        axi_wready      ;

wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr      ;
wire [3:0]                  axi_arid        ;
wire [3:0]                  axi_arlen       ;
wire                        axi_arready     ;
wire                        axi_arvalid     ;

wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata       ;
// Purpose: native DDR read ID=4 bits, LAST=1 bit.
wire [3:0] axi_rid;
wire axi_rlast;
wire                        axi_rvalid      ;

// Purpose: the native interface is not standard AXI: no WVALID/RREADY/B.
// Reserve FIFO bursts, convert 32-byte beat addresses to x32 physical words,
// and use controller-generated write ID/LAST. Fault stops future transactions.
wire native_wlast, native_dma_fault;
wire [3:0] native_wid;
mini_ddr_native_bridge u_native_dma (
 .clk(core_clk), .rst_n(mem_reset_n),
 .wr_req(wr_burst_req), .wr_beats(wr_burst_len), .wr_beat_addr(wr_burst_addr),
 .wr_data_req(wr_burst_data_req), .wr_data(wr_burst_data), .wr_finish(wr_burst_finish),
 .rd_req(rd_burst_req), .rd_beats(rd_burst_len), .rd_beat_addr(rd_burst_addr),
 .rd_data_valid(rd_burst_data_valid), .rd_data(rd_burst_data), .rd_finish(rd_burst_finish),
 .awaddr(axi_awaddr), .awlen(axi_awlen), .awid(axi_awid),
 .awvalid(axi_awvalid), .awready(axi_awready), .wdata(axi_wdata), .wstrb(axi_wstrb),
 .wready(axi_wready), .wid(native_wid), .wlast(native_wlast),
 .araddr(axi_araddr), .arlen(axi_arlen), .arid(axi_arid),
 .arvalid(axi_arvalid), .arready(axi_arready), .rdata(axi_rdata),
 .rvalid(axi_rvalid), .rid(axi_rid), .rlast(axi_rlast), .fault(native_dma_fault)
);
//=====================================================================================
//ddr
//=====================================================================================
wire clk_125Mhz ;

GTP_INBUFGDS #(
    .IOSTANDARD("DEFAULT"),
    .TERM_DIFF("ON")
) u_gtp (
    .O(clk_125Mhz), // OUTPUT  
    .I(clk_p), // INPUT  
    .IB(clk_n) // INPUT  
);

//ddr    
// Purpose: existing native 100H controller with hierarchy-bound DDR constraints.
wire pll_lock, phy_pll_lock, gpll_lock, rst_gpll_lock, ddrphy_cpd_lock;
ddr3_controller I_ips_ddr_top (
    .ref_clk                   (clk_125Mhz            ),
    .resetn                    (rst_in),// input
    .ddr_init_done             (ddr_init_done      ),// outpu
    .pll_lock                  (pll_lock           ),// outpu
    .core_clk                  (core_clk),                                  // outpu
    .phy_pll_lock              (phy_pll_lock),                          // output
    .gpll_lock                 (gpll_lock),                                // output
    .rst_gpll_lock             (rst_gpll_lock),                        // output
    .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output
    //.ddr_init_done             (ddr_init_done),                        // outpu
    .axi_awaddr                (axi_awaddr         ),// input [27:0]
    .axi_awuser_ap             (1'b0               ),// input
    .axi_awuser_id             (axi_awid           ),// input [3:0]
    .axi_awlen                 (axi_awlen          ),// input [3:0]
    .axi_awready               (axi_awready        ),// output
    .axi_awvalid               (axi_awvalid        ),// input

    .axi_wdata                 (axi_wdata          ),
    .axi_wstrb                 (axi_wstrb          ),// input [31:0]
    .axi_wready                (axi_wready         ),// output
    .axi_wusero_id             (native_wid         ),// output [3:0]
    .axi_wusero_last           (native_wlast       ),// output

    .axi_araddr                (axi_araddr         ),// input [27:0]
    .axi_aruser_ap             (1'b0               ),// input
    .axi_aruser_id             (axi_arid           ),// input [3:0]
    .axi_arlen                 (axi_arlen          ),// input [3:0]
    .axi_arready               (axi_arready        ),// output
    .axi_arvalid               (axi_arvalid        ),// input

    .axi_rdata                 (axi_rdata          ),// output [255:0]
    .axi_rid                   (axi_rid            ),// output [3:0]
    .axi_rlast                 (axi_rlast          ),// output
    .axi_rvalid                (axi_rvalid         ),// outpu

    .apb_clk                   (1'b0               ),// input
    .apb_rst_n                 (1'b1               ),// input
    .apb_sel                   (1'b0               ),// input
    .apb_enable                (1'b0               ),// input
    .apb_addr                  (8'b0               ),// input [7:0]
    .apb_write                 (1'b0               ),// input
    .apb_ready                 (                   ), // output
    .apb_wdata                 (16'b0              ),// input [15:0]
    .apb_rdata                 (                   ),// output [15:0]
//          .apb_int                   (                   ),// outpu
    .mem_rst_n                 (mem_rst_n          ),// output
    .mem_ck                    (mem_ck             ),// output
    .mem_ck_n                  (mem_ck_n           ),// output
    .mem_cke                   (mem_cke            ),// output
    .mem_cs_n                  (mem_cs_n           ),// output
    .mem_ras_n                 (mem_ras_n          ),// output
    .mem_cas_n                 (mem_cas_n          ),// output
    .mem_we_n                  (mem_we_n           ),// output
    .mem_odt                   (mem_odt            ),// output
    .mem_a                     (mem_a              ),// output [14:0]
    .mem_ba                    (mem_ba             ),// output [2:0]
    .mem_dqs                   (mem_dqs            ),// inout [3:0]
    .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
    .mem_dq                    (mem_dq             ),// inout [31:0]
    .mem_dm                    (mem_dm             ),// output [3:0]
    //debug

    .dbg_gate_start(1'b0),                      // input
    .dbg_cpd_start(1'b0),                        // input
    .dbg_ddrphy_rst_n(1'b1),                  // input
    .dbg_gpll_scan_rst(1'b0),                // input
    .samp_position_dyn_adj(1'b0),        // input
    .init_samp_position_even(32'd0),    // input [31:0]
    .init_samp_position_odd(32'd0),      // input [31:0]
    .wrcal_position_dyn_adj(1'b0),      // input
    .init_wrcal_position(32'd0),            // input [31:0]
    .force_read_clk_ctrl(1'b0),            // input
    .init_slip_step(16'd0),                      // input [15:0]
    .init_read_clk_ctrl(12'd0),              // input [11:0]
    .debug_calib_ctrl(),                  // output [33:0]
    .dbg_slice_status(),                  // output [67:0]
    .dbg_slice_state(),                    // output [87:0]
    .debug_data(),                              // output [275:0]
    .dbg_dll_upd_state(),                // output [1:0]
    .debug_gpll_dps_phase(),          // output [8:0]
    .dbg_rst_dps_state(),                // output [2:0]
    .dbg_tran_err_rst_cnt(),          // output [5:0]
    .dbg_ddrphy_init_fail(),          // output
    .debug_cpd_offset_adj(1'b0),          // input
    .debug_cpd_offset_dir(1'b0),          // input
    .debug_cpd_offset(10'd0),                  // input [9:0]
    .debug_dps_cnt_dir0(),              // output [9:0]
    .debug_dps_cnt_dir1(),              // output [9:0]
    .ck_dly_en(1'b0),                                // input
    .init_ck_dly_step(8'h0),                  // input [7:0]
    .ck_dly_set_bin(),                      // output [7:0]
    .align_error(),                            // output
    .debug_rst_state(),                    // output [3:0]
    .debug_cpd_state()                     // output [3:0]
);

//=====================================================================================
//心跳信号
//=====================================================================================
reg [26:0] cnt;
// Heartbeat shares the DDR domain reset, including async assertion on stopped
// clocks; it reports activity only, never successful frame/timing acceptance.
always@(posedge core_clk or negedge mem_reset_n) begin
    if (!mem_reset_n)
        cnt <= 27'd0;
    else if ( cnt >= TH_1S )
        cnt <= 27'd0;
    else
        cnt <= cnt + 27'd1;
end

always @(posedge core_clk or negedge mem_reset_n) begin
    if (!mem_reset_n)
        heart_beat_led <= 1'd1;
    else if ( cnt >= TH_1S )
        heart_beat_led <= ~heart_beat_led;
end

endmodule
