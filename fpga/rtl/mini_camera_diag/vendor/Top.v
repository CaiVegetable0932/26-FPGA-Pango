`timescale 1ns / 1ps
// Purpose: single-CAM1 720p RGB565 diagnostic adaptation of the MINI 200H demo.
// PG2L100H-6FBG676 only; no RAW8/PRAW network path. NOT RELEASED FOR DOWNLOAD:
// frame ownership, FIFO fault recovery and external timing still need validation.
module Top#(
	parameter MEM_ROW_ADDR_WIDTH   = 15         ,
	parameter MEM_COL_ADDR_WIDTH   = 10         ,
	parameter MEM_BADDR_WIDTH      = 3          ,
	parameter MEM_DQ_WIDTH         =  32        ,
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
    output  reg                                 cam_led1       ,
    // Purpose: active-high LED3/4 expose the selected diagnostic page's flags.
    output reg                                  capture_seen_led,
    output reg                                  display_ready_led
);
//=====================================================================================
//reg define
//=====================================================================================
// ENABLE_DDR
localparam CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;//28
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

// Purpose: share main's single-source native I/O clocks and the proven vendor
// PLL; preserve camera/DDR resets and release video only after divider startup.
wire pixel_reset_n, cam_reset_n, mem_reset_n;
wire hdmi_div_reset_n;
clk_hdmi u_video_pll(.clkin1(sys_clk), .clkout0(),
 .clkout1(serial_raw), .lock(locked0));
GTP_CLKBUFR u_hdmi_serial_clock(.CLKIN(serial_raw), .CLKOUT(pclkx5));
reset_sync rs_hdmi_div(pclkx5, rst_in && locked0, hdmi_div_reset_n);
GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_hdmi_pixel_div(
 .CLKIN(serial_raw), .RST_N(hdmi_div_reset_n), .CE(1'b1), .CLKDIVOUT(pclk));
hdmi_tx_powerup_reset u_hdmi_reset(.pixel_clk(pclk),
 .pll_locked(rst_in && locked0), .reset_n(pixel_reset_n));
reset_sync rs_sys(sys_clk, rst_in && locked0, rst_n);
reset_sync rs_camera(camera_clk_0, rst_in && locked0, cam_reset_n);
reset_sync rs_mem(core_clk, rst_in && ddr_init_done, mem_reset_n);

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

// Purpose: observer and capture consume one registered DVP bundle, not independent input paths.
wire sampled_vsync,sampled_href;
wire [7:0] sampled_data,capture_status;
wire [159:0] measure_packet,hdmi_diag_packet;
// Purpose: count geometry only AFTER verified configuration, independent of abort/warmup.
mini_dvp_measure u_dvp_measure(.clk(camera_clk_0),.reset_n(cam_reset_n),
 .cfg_ready(capture_status[1]),.vsync(sampled_vsync),.href(sampled_href),
 .capture_status(capture_status),.packet(measure_packet));
mini_diag_snapshot u_diag_snapshot(.src_clk(camera_clk_0),.src_reset_n(cam_reset_n),
 .dst_clk(pclk),.dst_reset_n(pixel_reset_n),.source(measure_packet),.snapshot(hdmi_diag_packet));
mini_dvp_input u_dvp_input(.clk(camera_clk_0),.reset_n(cam_reset_n),
 .vsync(camera_vsync_0),.href(camera_href_0),.data(camera_data_0),
 .sampled_vsync(sampled_vsync),.sampled_href(sampled_href),.sampled_data(sampled_data));
wire            cam_init_done_0;
wire            cam_init_done_1;

// Purpose: latch the first admitted camera pixel after configuration/warmup.
// This flag on diagnostic page 10 is not a full-frame proof.
reg pixel_seen;
always @(posedge camera_clk_0 or negedge cam_reset_n)
 if (!cam_reset_n) pixel_seen <= 1'b0;
 else if (cam_write_en_0) pixel_seen <= 1'b1;

camera camera_inst0(
    /*input   wire            */.clk           ( sys_clk             )  ,
    /*input   wire            */.rst_n         ( rst_n               )  ,
    /*output  wire            */.SCL           ( SCL_0               )  ,  
    /*output  wire            */.SDA           ( SDA_0               )  ,  
    /*input   wire            */.camera_clk    ( camera_clk_0        )  ,
    /*input   wire    [7:0]   */.camera_data   ( sampled_data        )  ,
    /*input   wire            */.camera_herf   ( sampled_href        )  ,
    /*input   wire            */.camera_vsync  ( sampled_vsync       )  ,
    /*input   wire            */.ddr_init      ( ddr_init_done       )  ,
    /*output  wire            */.camera_rstn   ( cam_rst_0           )  ,
    /*output  wire            */.camera_pwnd   ()  ,
    /*output  wire            */.init_done     ( cam_init_done_0     )  ,
    /*output  wire    [15:0]  */.wf_wr_data    ( cam_data_0          )  ,   //RGB565
    /*output  wire            */.wf_wr_en      ( cam_write_en_0      )  ,
    /*output  wire            */.vs            ( cam_vsync_0         )  ,
    /*output  wire            */.hs            ( cam_href_0          )  ,
    /*output  wire            */.sop           ()  ,
    /*output  wire            */.eop           (), .capture_status(capture_status)
);

// Purpose: eight two-second pages. LED2:LED1:LED0 is page number, not a heartbeat.
// Pages 0-3 keep old flag pairs; 4-7 show reset/config, DDR/warm-start,
// warm-done/frame-start, admitted-frame/bad-line from the actual capture domain.
// 00: raw VSYNC/HREF edges; 01: 2560-byte line/720-line frame;
// 10: admitted camera pixel/display-ready; 11: SCCB done/DDR initialized.
wire [3:0] raw_seen;
mini_dvp_observe u_raw_observe(.clk(camera_clk_0),.reset_n(cam_reset_n),
 .vsync(sampled_vsync),.href(sampled_href),.seen(raw_seen));
(* syn_preserve=1 *) reg [15:0] diagnostic_meta,diagnostic_sync;
reg [25:0] diagnostic_tick;
reg [2:0] diagnostic_page;
always @(posedge sys_clk or negedge rst_n)
 if(!rst_n) begin
  diagnostic_meta<=0;diagnostic_sync<=0;diagnostic_tick<=0;diagnostic_page<=0;
  cam_led0<=0;cam_led1<=0;heart_beat_led<=0;capture_seen_led<=0;display_ready_led<=0;
 end else begin
  // Purpose: each independent sticky/status bit crosses through two registers.
  diagnostic_meta<={capture_status,ddr_init_done,cam_init_done_0,pool_display_valid,pixel_seen,raw_seen};
  diagnostic_sync<=diagnostic_meta;
  if(diagnostic_tick==26'd53999999) begin diagnostic_tick<=0;diagnostic_page<=diagnostic_page+1'b1;end
  else diagnostic_tick<=diagnostic_tick+1'b1;
  cam_led0<=diagnostic_page[0];cam_led1<=diagnostic_page[1];heart_beat_led<=diagnostic_page[2];
  case(diagnostic_page)
   0: begin capture_seen_led<=diagnostic_sync[0];display_ready_led<=diagnostic_sync[1];end
   1: begin capture_seen_led<=diagnostic_sync[2];display_ready_led<=diagnostic_sync[3];end
   2: begin capture_seen_led<=diagnostic_sync[4];display_ready_led<=diagnostic_sync[5];end
   3: begin capture_seen_led<=diagnostic_sync[6];display_ready_led<=diagnostic_sync[7];end
   4: begin capture_seen_led<=diagnostic_sync[8];display_ready_led<=diagnostic_sync[9];end
   5: begin capture_seen_led<=diagnostic_sync[10];display_ready_led<=diagnostic_sync[11];end
   6: begin capture_seen_led<=diagnostic_sync[12];display_ready_led<=diagnostic_sync[13];end
   7: begin capture_seen_led<=diagnostic_sync[14];display_ready_led<=diagnostic_sync[15];end
  endcase
 end
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
// Purpose: preserve the real DDR scanout and its aligned blanking controls.
// Before a complete camera frame exists, transmit explicitly diagnostic telemetry.
// This synthetic raster is never advertised as a camera image or a source-ID proof.
wire [23:0] camera_rgb888;
hdmi_rgb565_expand u_rgb_expand(.rgb565(vout_data_0), .rgb888(camera_rgb888));
wire [23:0] diagnostic_rgb;
mini_diag_raster u_diag_raster(.clk(pclk),.reset_n(pixel_reset_n),
 .vsync(vs_out),.de(de_out),.packet(hdmi_diag_packet),.rgb(diagnostic_rgb));
assign vout_data = display_valid_sync ? camera_rgb888 : diagnostic_rgb;
hdmi_tx_rgb u_hdmi_tx(.pixel_clk(pclk), .serial_clk(pclkx5),
 .reset_n(pixel_reset_n), .rgb(vout_data), .data_enable(de_out),
 .hsync(hs_out), .vsync(vs_out), .tmds_clk_p(tmds_clk_p),
 .tmds_clk_n(tmds_clk_n), .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n));

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
// Purpose: export display admission on LED4/page 10, not as image proof.
// Status is exported through diagnostic_sync to the selected LED page above.
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

wire axi_bvalid;
// Purpose: make the vendor generic AXI-to-native DDR width conversion explicit.
// Four 2 MiB slots fit 28 address bits; bursts are fixed at 16 beats (LEN=15).
// Only transaction ID zero is issued. Wider/high-bit behavior is not supported.
wire [31:0] adapter_awaddr, adapter_araddr;
wire [7:0] adapter_awlen, adapter_arlen;
wire adapter_awid, adapter_arid;
assign axi_awaddr=adapter_awaddr[27:0], axi_araddr=adapter_araddr[27:0];
assign axi_awlen=adapter_awlen[3:0], axi_arlen=adapter_arlen[3:0];
assign axi_awid={3'b0,adapter_awid}, axi_arid={3'b0,adapter_arid};
// Native DDR has no AXI B channel; retain the vendor adapter convention only.
// Its write-completion semantics still require a transaction-level regression.
assign axi_bvalid =1'b1;
aq_axi_master_256	u_aq_axi_master (
	  .ARESETN                     (mem_reset_n          ), // DDR-domain reset release.
	  .ACLK                        (core_clk              ),
	  .M_AXI_AWID                  (adapter_awid      ),
	  .M_AXI_AWADDR                (adapter_awaddr    ),
	  .M_AXI_AWLEN                 (adapter_awlen     ),
	  .M_AXI_AWSIZE                (),
	  .M_AXI_AWBURST               (),
	  .M_AXI_AWLOCK                (),
	  .M_AXI_AWCACHE               (),
	  .M_AXI_AWPROT                (),
	  .M_AXI_AWQOS                 (),
	  .M_AXI_AWUSER                (),
	  .M_AXI_AWVALID               (axi_awvalid       ),
	  .M_AXI_AWREADY               (axi_awready       ),

	  .M_AXI_WDATA                 (axi_wdata         ),
	  .M_AXI_WSTRB                 (axi_wstrb         ),
	  .M_AXI_WLAST                 (),
	  .M_AXI_WUSER                 (),
	  .M_AXI_WVALID                (),
	  .M_AXI_WREADY                (axi_wready        ),

	  .M_AXI_BID                   (),
	  .M_AXI_BRESP                 (),
	  .M_AXI_BUSER                 (),
      .M_AXI_BVALID                (axi_bvalid        ),
	  .M_AXI_BREADY                (),

	  .M_AXI_ARID                  (adapter_arid      ),
	  .M_AXI_ARADDR                (adapter_araddr    ),
	  .M_AXI_ARLEN                 (adapter_arlen     ),
	  .M_AXI_ARSIZE                (),
	  .M_AXI_ARBURST               (),
	  .M_AXI_ARLOCK                (),
	  .M_AXI_ARCACHE               (),
	  .M_AXI_ARPROT                (),
	  .M_AXI_ARQOS                 (),
	  .M_AXI_ARUSER                (),
	  .M_AXI_ARVALID               (axi_arvalid       ),
	  .M_AXI_ARREADY               (axi_arready       ),

	  .M_AXI_RID                   (axi_rid[0]        ),
	  .M_AXI_RDATA                 (axi_rdata         ),
	  .M_AXI_RRESP                 (),
	  .M_AXI_RLAST                 (axi_rlast         ),
	  .M_AXI_RUSER                 (),
	  .M_AXI_RVALID                (axi_rvalid        ),
	  .M_AXI_RREADY                (),

	  .MASTER_RST                  (1'b0                  ),
	  .WR_START                    (wr_burst_req          ),
	  .WR_ADRS                     ({wr_burst_addr[22:0],5'd0}  ),
	  .WR_LEN                      ({wr_burst_len, 5'd0}  ),
	  .WR_READY                    (                      ),
	  .WR_FIFO_RE                  (wr_burst_data_req     ),
	  .WR_FIFO_EMPTY               (1'b0                  ),
	  .WR_FIFO_AEMPTY              (1'b0                  ),
	  .WR_FIFO_DATA                (wr_burst_data         ),
	  .WR_DONE                     (wr_burst_finish       ),
	  .RD_START                    (rd_burst_req          ),
	  .RD_ADRS                     ({rd_burst_addr[22:0],5'd0}  ),
	  .RD_LEN                      ({rd_burst_len, 5'd0}   ),
	  .RD_READY                    (                      ),
	  .RD_FIFO_WE                  (rd_burst_data_valid   ),
	  .RD_FIFO_FULL                (1'b0                  ),
	  .RD_FIFO_AFULL               (1'b0                  ),
	  .RD_FIFO_DATA                (rd_burst_data         ),
	  .RD_DONE                     (rd_burst_finish       ),
	  .DEBUG                       (                      )
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
    .axi_wusero_id             (                   ),// output [3:0]
    .axi_wusero_last           (),// output

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
// Purpose: LED2 is now driven only by the sys_clk diagnostic page sequencer.
//=====================================================================================

endmodule
