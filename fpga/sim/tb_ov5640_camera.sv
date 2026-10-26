`timescale 1ns/1ps
// 用途：固定组最终回读前不开放采集，初始化表与服务共用真实 SCCB 引脚。
// 本用例缩短复位/等待并模拟寄存器，不包含真实 DDR、帧池或相机响应。
module tb_ov5640_camera #(parameter FIXED_MODE=1);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    tri1 scl,sda; wire ready; wire [2:0] fault;wire [31:0] version;
    wire reset_sensor,pwnd;
    integer starts,stops,writes,reads,nacks;
    reg sensor_reset_n=0;
    camera #(.FIXED_MODE(FIXED_MODE),.EXPOSURE(20'd2051),.EXPECT_HTS(16'h09c0),.EXPECT_VTS(16'h04c8),
        .CTRL_CLK_HZ(3200),.SCCB_CLK_HZ(100),.POWERUP_CYCLES(8),.RESET_CYCLES(8),
        .SCCB_DELAY_CYCLES(8),.WRITE_WAIT_CYCLES(8),.RESET_WAIT_CYCLES(16)) dut(
        .clk(clk),.rst_n(rst_n),.SCL(scl),.SDA(sda),.camera_clk(clk),.camera_data(8'b0),
        .camera_herf(1'b0),.camera_vsync(1'b1),.ddr_init(1'b1),
        .camera_rstn(reset_sensor),.camera_pwnd(pwnd),.init_done(ready),
        .query_start(1'b0),.query_addr(16'b0),.config_fault(fault),.config_version(version));
    ov5640_sccb_model sensor(sensor_reset_n,scl,sda,4'b0,1'b0,starts,stops,writes,reads,nacks);
    always @(posedge clk)if(rst_n && !ready && dut.wf_wr_en)$fatal(1,"EARLY_CAPTURE");
    initial begin
        for(integer i=0;i<65536;i=i+1)sensor.memory[i]=0;
        sensor.memory[16'h300a]=8'h56;sensor.memory[16'h300b]=8'h40;
        repeat(8)@(negedge clk);rst_n=1;sensor_reset_n=1;
        wait(ready);#1;
        if(fault!=0 || version!=(FIXED_MODE?1:0) || writes!=(FIXED_MODE?260:244) || reads!=(FIXED_MODE?88:36) || nacks!=(FIXED_MODE?88:36))
            $fatal(1,"CAMERA_BOOT_FAIL fault=%d version=%d writes=%d reads=%d",fault,version,writes,reads);
        if(FIXED_MODE && {sensor.memory[16'h3500][3:0],sensor.memory[16'h3501],sensor.memory[16'h3502]}!=20'd2051)
            $fatal(1,"CAMERA_EXPOSURE_FAIL");
        repeat(100)@(negedge clk);
        if(writes!=(FIXED_MODE?260:244) || reads!=(FIXED_MODE?88:36))$fatal(1,"CAMERA_EXTRA_TRANSACTION");
        if(FIXED_MODE)$display("OV5640_CAMERA_PASS vendor_writes=244 fixed_writes=16 reads=88");
        else $display("OV5640_CAMERA_AUTO_PASS vendor_writes=244 fixed_writes=0 reads=36");
        $finish;
    end
    initial begin #10000000;$fatal(1,"OV5640_CAMERA_TIMEOUT");end
endmodule

// 用途：独立回归默认自动诊断路径，确保身份快照新增后仍可以正常开放采集。
module tb_ov5640_camera_auto;
    tb_ov5640_camera #(.FIXED_MODE(0)) scenario();
endmodule
