`timescale 1ns/1ps
// Purpose: complete MINI camera initialization owned by one SCCB service:
// read-only chip ID -> analog standby table -> historical RAW profile readback
// -> explicit fixed-exposure 1080p RAW tap-3 group -> stream-on/readback.
// Ready is a register-configuration state, not proof of optical timing/Bayer.
module ov5640_integrated_startup #(
 parameter SYS_CLK=27000000,SCCB_CLK=100000,
 parameter RESET_CYCLES=270000,BOOT_CYCLES=1080000,WRITE_WAIT=27000,SOFT_RESET_WAIT=135000,
 parameter SERVICE_TIMEOUT=SYS_CLK,GROUP_TIMEOUT=SYS_CLK*4,
 parameter [19:0] EXPOSURE_CODE=20'd10752,parameter [9:0] GAIN_CODE=10'd16
)(
 input clk,rst_n,inout SCL,SDA,output sensor_reset_n,output reg ready,output failed,
 output reg [3:0] failure_code,output [31:0] active_version,active_entity
);
 localparam HOLD=0,BOOT=1,BASE=2,PATCH=3,VERIFY_SEND=4,VERIFY_WAIT=5,
  APPLY=6,MODE_WAIT=7,STREAM_SEND=8,STREAM_WAIT=9,RUN=10,FAIL=11,ID_SEND=12,ID_WAIT=13;
 reg [3:0] state;reg [31:0] timer;reg init_finished,patch_start,patch_pending,mode_apply,id_start,id_low;
 reg [6:0] index;wire [23:0] profile,base_data;wire profile_last,base_start,base_done,init_end,init_failed;
 reg boot_cmd_valid,boot_cmd_write;reg [15:0] boot_cmd_addr;reg [7:0] boot_cmd_value,boot_cmd_mask;
 reg [31:0] boot_cookie;
 wire mode_cmd_valid,mode_cmd_write,cmd_ready,rsp_valid,mode_apply_ready,mode_done,mode_ready;
 wire [15:0] mode_cmd_addr;wire [7:0] mode_cmd_value,mode_cmd_mask,rsp_value;
 wire [31:0] mode_cookie,rsp_cookie;wire [2:0] rsp_status,mode_status;
 wire use_mode=state==APPLY || state==MODE_WAIT;
 wire identifying=state==ID_SEND || state==ID_WAIT;wire [7:0] identity_value;
 assign sensor_reset_n=rst_n && state!=HOLD && state!=FAIL;
 assign failed=state==FAIL;
 // Preserve the original analog table while keeping the sensor in standby.
 // The reviewed RAW profile then replaces all relevant 720p/RGB controls.
 wire [23:0] standby_data=base_data==24'h300802 ? 24'h300842 :
  base_data==24'h310302 ? 24'h310303 : base_data;
 data_init #(.CNT_WAIT_MAX(WRITE_WAIT),.RESET_WAIT_MAX(SOFT_RESET_WAIT)) analog(
  .sys_clk(clk),.sys_rst_n(rst_n && state==BASE),.cfg_end(init_end && state==BASE),
  .cfg_start(base_start),.cfg_data(base_data),.cfg_done(base_done));
 ov5640_reference_profile raw_profile(.index(index),.value(profile),.last(profile_last));
 ov5640_register_service #(.SYS_CLK(SYS_CLK),.SCCB_CLK(SCCB_CLK),
  .STRETCH_TIMEOUT(SYS_CLK/10),.SERVICE_TIMEOUT(SERVICE_TIMEOUT),.INIT_READ_ENABLE(1)) service(
  .clk(clk),.rst_n(rst_n && state!=FAIL),.init_finished(init_finished),
  .init_start(identifying ? id_start : (state==BASE ? base_start : patch_start)),
  .init_data(identifying ? (id_low ? 24'h300b00 : 24'h300a00) : (state==BASE ? standby_data : profile)),
  .init_read(identifying),.init_read_value(identity_value),
  .init_end(init_end),.init_failed(init_failed),.quiesced(1'b1),
  .cmd_valid(use_mode ? mode_cmd_valid : boot_cmd_valid),.cmd_ready(cmd_ready),
  .cmd_write(use_mode ? mode_cmd_write : boot_cmd_write),.cmd_addr(use_mode ? mode_cmd_addr : boot_cmd_addr),
  .cmd_value(use_mode ? mode_cmd_value : boot_cmd_value),.cmd_mask(use_mode ? mode_cmd_mask : boot_cmd_mask),
  .cmd_cookie(use_mode ? mode_cookie : boot_cookie),.rsp_valid(rsp_valid),.rsp_status(rsp_status),
  .rsp_value(rsp_value),.rsp_cookie(rsp_cookie),.SCL(SCL),.SDA(SDA));
 ov5640_raw8_mode #(.RAW_OUTPUT_SELECT(8'h03),.GROUP_TIMEOUT(GROUP_TIMEOUT)) mode(
  .clk(clk),.rst_n(rst_n),.quiesced(1'b1),.apply(mode_apply),.apply_ready(mode_apply_ready),
  .width(16'd1920),.height(16'd1080),.hts(16'd2500),.vts(16'd1120),
  .x_start(16'd336),.y_start(16'd434),.x_end(16'd2287),.y_end(16'd1521),.x_offset(16'd16),.y_offset(16'd4),
  .pll3034(8'h18),.pll3035(8'h11),.pll3036(8'h54),.pll3037(8'h13),.root3108(8'h01),
  .x_inc(8'h11),.y_inc(8'h11),.flip3820(8'h40),.mirror3821(8'h06),.bayer_code(3'd4),
  .exposure(EXPOSURE_CODE),.gain(GAIN_CODE),.requested_version(32'd1),.parameter_entity(32'd1),
  .cmd_valid(mode_cmd_valid),.cmd_ready(cmd_ready),.cmd_write(mode_cmd_write),.cmd_addr(mode_cmd_addr),
  .cmd_value(mode_cmd_value),.cmd_mask(mode_cmd_mask),.cmd_cookie(mode_cookie),
  .rsp_valid(rsp_valid),.rsp_status(rsp_status),.rsp_value(rsp_value),.rsp_cookie(rsp_cookie),
  .done(mode_done),.status(mode_status),.mode_ready(mode_ready),.active_version(active_version),.active_entity(active_entity));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin ready<=0;state<=HOLD;timer<=0;init_finished<=0;patch_start<=0;patch_pending<=0;
   mode_apply<=0;index<=0;boot_cmd_valid<=0;boot_cmd_write<=0;boot_cmd_addr<=0;boot_cmd_value<=0;
   boot_cmd_mask<=0;boot_cookie<=0;failure_code<=0;id_start<=0;id_low<=0;end
  else begin
   // Only this registered commissioning level crosses into the DVP ready
   // synchronizer/watchdog; table lookup and FSM decode stay in SCCB domain.
   ready<=state==RUN;
   patch_start<=0;boot_cmd_valid<=0;mode_apply<=0;id_start<=0;
   if(init_failed && !init_finished)begin state<=FAIL;failure_code<=1;end
   else case(state)
    HOLD:if(timer>=RESET_CYCLES-1)begin timer<=0;state<=BOOT;end else timer<=timer+1;
    BOOT:if(timer>=BOOT_CYCLES-1)begin timer<=0;state<=ID_SEND;end else timer<=timer+1;
    // No sensor register is written until both read-only identity bytes match.
    ID_SEND:begin id_start<=1;state<=ID_WAIT;end
    ID_WAIT:if(init_end)begin
     if(identity_value!=(id_low ? 8'h40 : 8'h56))begin state<=FAIL;failure_code<=5;end
     else if(id_low)state<=BASE;else begin id_low<=1;state<=ID_SEND;end
    end
    BASE:if(base_done)begin state<=PATCH;index<=0;patch_pending<=0;end
    PATCH:begin
     if(!patch_pending)begin patch_start<=1;patch_pending<=1;end
     if(init_end)begin
      patch_pending<=0;
      if(profile_last)begin init_finished<=1;index<=0;state<=VERIFY_SEND;end else index<=index+1;
     end
    end
    VERIFY_SEND:if(cmd_ready)begin
     boot_cmd_valid<=1;boot_cmd_write<=0;boot_cmd_addr<=profile[23:8];boot_cmd_mask<=0;
     boot_cookie<={25'h1000000,index};state<=VERIFY_WAIT;
    end
    VERIFY_WAIT:if(rsp_valid)begin
     if(rsp_status!=0 || rsp_value!=profile[7:0] || rsp_cookie!={25'h1000000,index})begin state<=FAIL;failure_code<=2;end
     else if(profile_last)state<=APPLY;else begin index<=index+1;state<=VERIFY_SEND;end
    end
    APPLY:if(mode_apply_ready)begin mode_apply<=1;state<=MODE_WAIT;end
    MODE_WAIT:if(mode_done)begin
     if(mode_status!=0 || !mode_ready)begin state<=FAIL;failure_code<=3;end else state<=STREAM_SEND;
    end
    STREAM_SEND:if(cmd_ready)begin
     boot_cmd_valid<=1;boot_cmd_write<=1;boot_cmd_addr<=16'h3008;boot_cmd_value<=8'h02;
     boot_cmd_mask<=8'hff;boot_cookie<=32'hffffffff;state<=STREAM_WAIT;
    end
    STREAM_WAIT:if(rsp_valid)begin
     if(rsp_status!=0 || rsp_value!=8'h02 || rsp_cookie!=32'hffffffff)begin state<=FAIL;failure_code<=4;end
     else state<=RUN;
    end
    RUN:begin end
    FAIL:begin end
    default:begin state<=FAIL;failure_code<=15;end
   endcase
  end
 end
endmodule
