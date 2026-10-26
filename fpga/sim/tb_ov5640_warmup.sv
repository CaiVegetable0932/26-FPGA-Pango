`timescale 1ns/1ps
// 用途：只有就绪后完整计数的帧才能完成预热；就绪掉线会重新预热并在帧边界恢复。
module tb_ov5640_warmup;
    reg clk=0,rst_n=0,vsync=1,href=0,cfg=0,ddr=1;
    always #5 clk=~clk;
    wire wr,sop,eop,vs,hs;wire [15:0] pixel;
    integer checks=0;
    camera_data #(.FRAME_WIDTH(1),.FRAME_HEIGHT(1),.WARMUP_FRAMES(2)) dut(
        clk,rst_n,vsync,href,8'h55,cfg,ddr,pixel,wr,sop,eop,vs,hs);
    task tick(input v,input h);begin @(negedge clk);vsync=v;href=h;@(posedge clk);#1;end endtask
    task frame(input expected_write);
        begin repeat(5)tick(1,0);repeat(6)tick(0,0);tick(0,1);tick(0,1);
        checks=checks+1;if(wr!==expected_write)$fatal(1,"WARMUP_WRITE_FAIL frame=%d wr=%b",checks,wr);
        repeat(4)tick(0,0);end
    endtask
    initial begin
        repeat(5)tick(1,0);rst_n=1;frame(0);frame(0);
        cfg=1;repeat(5)tick(1,0);frame(0);frame(0);frame(1);
        cfg=0;repeat(6)tick(0,0);cfg=1;repeat(5)tick(0,0);frame(0);frame(0);frame(1);
        ddr=0;repeat(6)tick(0,0);ddr=1;repeat(5)tick(0,0);frame(0);frame(0);frame(1);
        $display("OV5640_WARMUP_PASS checks=%d",checks);$finish;
    end
    initial begin #100000;$fatal(1,"OV5640_WARMUP_TIMEOUT");end
endmodule
