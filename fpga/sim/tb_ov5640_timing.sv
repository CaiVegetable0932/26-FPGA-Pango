`timescale 1ns/1ps
// 用途：验证控制时钟节拍计数不混入垂直消隐，并检验重置/首样本有效标记。
module tb_ov5640_timing;
    reg clk=0,rst_n=0,href=0,vsync=0;
    always #5 clk=~clk;
    wire [31:0] row_ticks,frame_ticks,frames;wire row_valid,frame_valid;
    ov5640_timing_monitor dut(clk,rst_n,href,vsync,row_ticks,frame_ticks,frames,row_valid,frame_valid);
    task step(input integer n);begin repeat(n)@(negedge clk);end endtask
    initial begin
        step(5);rst_n=1;vsync=1;step(10);vsync=0;step(10);
        if(frame_valid)$fatal(1,"FIRST_FRAME_NOT_VALID");
        href=1;step(5);href=0;step(15);href=1;step(5);
        if(!row_valid || row_ticks!=20)$fatal(1,"ROW_INTERVAL_FAIL %d",row_ticks);
        href=0;step(15);vsync=1;step(10);
        if(!frame_valid || frame_ticks!=60 || frames!=2)$fatal(1,"FRAME_INTERVAL_FAIL %d",frame_ticks);
        vsync=0;step(100);href=1;step(5);
        if(row_ticks!=20)$fatal(1,"VERTICAL_GAP_MUST_NOT_BECOME_ROW");
        rst_n=0;step(5);if(row_valid || frame_valid || frames!=0)$fatal(1,"TIMING_RESET_FAIL");
        $display("OV5640_TIMING_PASS");$finish;
    end
    initial begin #10000;$fatal(1,"OV5640_TIMING_TIMEOUT");end
endmodule
