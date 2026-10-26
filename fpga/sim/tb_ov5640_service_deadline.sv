`timescale 1ns/1ps
// 用途：单寄存器与整组服务的独立期限，验证失去服务响应时有界退出并释放SCCB。
module tb_ov5640_service_deadline;
 reg clk=0,rst_n=0,cmd=0;always #5 clk=~clk;
 wire ready,rsp;wire [2:0] status;tri1 scl,sda;
 integer starts,stops,writes,reads,nacks;
 ov5640_register_service #(.SYS_CLK(3200),.SCCB_CLK(100),.SERVICE_TIMEOUT(100)) service(
 .clk(clk),.rst_n(rst_n),.init_finished(1'b1),.init_start(1'b0),.init_data(24'b0),
 .quiesced(1'b1),.cmd_valid(cmd),.cmd_ready(ready),.cmd_write(1'b0),.cmd_addr(16'h300a),
 .cmd_value(8'b0),.cmd_mask(8'b0),.cmd_cookie(32'd1),.rsp_valid(rsp),.rsp_status(status),.SCL(scl),.SDA(sda));
 ov5640_sccb_model sensor(rst_n,scl,sda,4'b0,1'b0,starts,stops,writes,reads,nacks);
 // 另一路组提交只接受请求，不给响应；组级deadline必须独立于SCCB超时起作用。
 wire mode_done,mode_ready;wire [2:0] mode_status;reg group_timeout_seen=0;
 ov5640_raw8_mode #(.GROUP_TIMEOUT(100)) mode_deadline(
 .clk(clk),.rst_n(rst_n),.quiesced(1'b1),.apply(cmd),
 .width(16'd1920),.height(16'd1080),.hts(16'd2500),.vts(16'd1125),
 .x_start(16'd336),.y_start(16'd434),.x_end(16'd2255),.y_end(16'd1513),.x_offset(16'b0),.y_offset(16'b0),
 .pll3034(8'h1a),.pll3035(8'h11),.pll3036(8'h3c),.pll3037(8'h13),.root3108(8'h01),
 .x_inc(8'h11),.y_inc(8'h11),.flip3820(8'h40),.mirror3821(8'h00),.bayer_code(3'd1),
 .exposure(20'd2560),.gain(10'h010),.requested_version(32'd1),.parameter_entity(32'd1),
 .cmd_ready(1'b1),.rsp_valid(1'b0),.rsp_status(3'b0),.rsp_value(8'b0),.rsp_cookie(32'b0),
 .done(mode_done),.status(mode_status),.mode_ready(mode_ready));
 always @(posedge clk)begin #1;if(mode_done && mode_status==2)group_timeout_seen=1;end
 integer cycles=0;
 always @(posedge clk)if(rst_n && !rsp)cycles=cycles+1;
 initial begin
 sensor.memory[16'h300a]=8'h56;repeat(8)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);
 cmd=1;@(negedge clk);cmd=0;wait(rsp);#1;
 if(status!=2 || cycles>120)$fatal(1,"REGISTER_DEADLINE_FAIL");
 repeat(8)@(negedge clk);if(scl!==1'b1 || sda!==1'b1 || !ready)$fatal(1,"DEADLINE_RELEASE_FAIL");
 if(!group_timeout_seen || mode_ready)$fatal(1,"GROUP_DEADLINE_FAIL");
 $display("OV5640_SERVICE_DEADLINE_PASS bounded_cycles=%d",cycles);$finish;
 end
 initial begin #100000;$fatal(1,"OV5640_SERVICE_DEADLINE_TIMEOUT");end
endmodule
