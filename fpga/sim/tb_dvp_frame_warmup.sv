`timescale 1ns/1ps
// 用途：只用完整合法帧推进预热，坏预热帧重新开始；正常运行坏帧后不额外丢十帧。
module tb_dvp_frame_warmup;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg href=0,vsync=1,cfg=0,enable=0;wire valid,done,legal;integer count=0;
 dvp_frame_receiver #(.MAX_WIDTH(4),.MAX_HEIGHT(4),.WARMUP_FRAMES(2),.FRAME_TIMEOUT(100)) dut(
 .pclk(clk),.rst_n(rst_n),.dvp_data(8'h55),.href(href),.vsync(vsync),.capture_enable(enable),
 .pipeline_drained(1'b1),.cfg_valid(cfg),.cfg_width(16'd2),.cfg_height(16'd2),.cfg_bayer(3'd1),
 .cfg_version(32'd1),.cfg_entity(32'd1),.token_valid(1'b1),.next_frame_tag(160'h1),.input_overflow(1'b0),
 .pixel_valid(valid),.frame_end(done),.frame_legal(legal));
 always @(posedge clk)begin #2;if(valid)count=count+1;end
 task tick(input v,input h);begin @(negedge clk);vsync=v;href=h;@(posedge clk);#3;end endtask
 task frame(input bad,input expected);
 begin count=0;repeat(4)tick(1,0);repeat(4)tick(0,0);
 for(integer y=0;y<2;y=y+1)begin tick(0,1);if(!(bad && y==0))tick(0,1);repeat(3)tick(0,0);end
 tick(1,0);tick(1,0);if(!done || legal!==expected || (expected && count!=4))$fatal(1,"FRAME_WARMUP_FAIL");
 end endtask
 initial begin
 repeat(5)tick(1,0);rst_n=1;cfg=1;tick(1,0);cfg=0;enable=1;
 frame(0,0);frame(1,0);frame(0,0);frame(0,0);frame(0,1);
 frame(1,0);frame(0,1);
 enable=0;repeat(5)tick(1,0);enable=1;frame(0,0);frame(0,0);frame(0,1);
 $display("DVP_FRAME_WARMUP_PASS");$finish;
 end
 initial begin #100000;$fatal(1,"DVP_FRAME_WARMUP_TIMEOUT");end
endmodule
