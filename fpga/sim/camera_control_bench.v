`timescale 1ns/1ps
// 用途：只验证RAW8配置器和SCCB服务在PG2L100H的原生编译/综合，不连接真实相机或板级IO。
// quiesced/申请参数为此控制时钟域基准输入；真实集成须由07/01提供握手和实物时钟证据。
module camera_control_bench(
 input wire clk,rst_in,apply,quiesced,input wire [31:0] seed,
 inout wire SCL,SDA,output wire [31:0] active_version,active_entity,
 output wire [5:0] status,output wire [31:0] returned_cookie
);
 wire rst_n;reset_sync reset_domain(clk,rst_in,rst_n);
 wire cmd,cmdready,wr,rsp,mode_ready,done,rejected,apply_ready;
 wire [15:0] addr;wire [7:0] value,mask,rsp_value;wire [31:0] cookie,rspcookie;
 wire [2:0] mode_status,rsp_status;
 ov5640_raw8_mode mode(.clk(clk),.rst_n(rst_n),.quiesced(quiesced),.apply(apply),.apply_ready(apply_ready),
 .width(16'd1920),.height(16'd1080),.hts(16'd2500),.vts(16'd1125),
 .x_start(16'd336),.y_start(16'd434),.x_end(16'd2255),.y_end(16'd1513),.x_offset(16'b0),.y_offset(16'b0),
 .pll3034(8'h1a),.pll3035(8'h11),.pll3036(seed[7:0]),.pll3037(8'h13),.root3108(8'h01),
 .x_inc(8'h11),.y_inc(8'h11),.flip3820(8'h40),.mirror3821(8'h00),.bayer_code(3'd1),
 .exposure(seed[19:0]),.gain(seed[9:0]),.requested_version(seed),.parameter_entity(seed^32'h1234),
 .cmd_valid(cmd),.cmd_ready(cmdready),.cmd_write(wr),.cmd_addr(addr),.cmd_value(value),.cmd_mask(mask),.cmd_cookie(cookie),
 .rsp_valid(rsp),.rsp_status(rsp_status),.rsp_value(rsp_value),.rsp_cookie(rspcookie),
 .done(done),.rejected(rejected),.status(mode_status),.mode_ready(mode_ready),.active_version(active_version),.active_entity(active_entity));
 ov5640_register_service service(.clk(clk),.rst_n(rst_n),.init_finished(1'b1),.init_start(1'b0),.init_data(24'b0),
 .quiesced(quiesced),.cmd_valid(cmd),.cmd_ready(cmdready),.cmd_write(wr),.cmd_addr(addr),.cmd_value(value),.cmd_mask(mask),
 .cmd_cookie(cookie),.rsp_valid(rsp),.rsp_status(rsp_status),.rsp_value(rsp_value),.rsp_cookie(rspcookie),.SCL(SCL),.SDA(SDA));
 assign status={apply_ready,done,mode_ready,mode_status};
 assign returned_cookie=rspcookie ^ {31'b0,rejected};
endmodule
