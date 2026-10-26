`timescale 1ns/1ps
// 模块用途：从外部 SCL/SDA 引脚解码 SCCB 字节并产生 ACK，不依赖主机内部状态推导期望数据。
module mini_sccb_slave_model(
    input wire reset_n, input wire scl, inout wire sda,
    input wire [3:0] ack_mask,
    output integer starts, output integer stops, output integer bytes,
    output reg [31:0] packet
);
    reg receiving=0, ack_drive=0;
    integer bit_count=0;
    reg [7:0] shift=0;
    assign sda = ack_drive ? 1'b0 : 1'bz;
    initial begin starts=0; stops=0; bytes=0; packet=0; end
    // START/STOP 仅由 SCL 高电平期间 SDA 的跳变确定。
    always @(negedge sda) if (reset_n && scl===1'b1) begin
        receiving=1; bit_count=0; bytes=0; shift=0; packet=0; starts=starts+1;
    end
    always @(posedge sda) if (reset_n && receiving && scl===1'b1) begin
        receiving=0; stops=stops+1;
    end
    always @(posedge scl) if (reset_n && receiving) begin
        if (bit_count<8) begin
            shift={shift[6:0],sda}; bit_count=bit_count+1;
            if (bit_count==8) begin packet={packet[23:0],shift}; bytes=bytes+1; end
        end else bit_count=0;
    end
    // 第九拍只在 SCL 为低时拉低/释放 SDA，模拟真实开漏应答。
    always @(negedge scl) begin
        if (reset_n && receiving && bit_count==8 && bytes<=4)
            ack_drive<=ack_mask[bytes-1];
        else ack_drive<=0;
    end
    always @(negedge reset_n) begin
        receiving=0; ack_drive=0; starts=0; stops=0; bytes=0; bit_count=0; packet=0;
    end
endmodule

// 模块用途：验证锁存写事务、逐字节 ACK/NACK、忙时请求、开漏释放、时钟拉伸超时以及完整配置表。
// 时钟分频参数缩短仿真；这不是板端总线频率或电平实测，且不访问任何摄像头硬件。
module tb_mini_sccb;
    reg clk=0;
    always #5 clk=~clk;
    reg reset_n=0, start=0, stretch=0;
    reg [23:0] data=0;
    reg [3:0] ack_mask=4'hf;
    tri1 scl,sda;
    wire done,error,busy;
    integer starts,stops,bytes;
    wire [31:0] packet;
    assign scl=stretch ? 1'b0 : 1'bz;
    // 用途：旧写事务回归明确关闭新增读入口，保留独立黄金向量的验证语义。
    SCCB #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(80)) dut(
        .clk(clk),.rst_n(reset_n),.sccb_start(start),.data_in(data),.sccb_read(1'b0),.read_data(),.error_code(),
        .SCL(scl),.SDA(sda),.sccb_done(done),.sccb_error(error),.busy(busy));
    mini_sccb_slave_model slave(reset_n,scl,sda,ack_mask,starts,stops,bytes,packet);
    integer checks=0, manual_cases=0;

    // 独立第二条总线，将厂商配置表实际串行化，逐项与原始参考提取的黄金数据比较。
    reg cfg_reset_n=0;
    wire cfg_start,cfg_done,tx_done,tx_error,tx_busy;
    wire [23:0] cfg_data;
    tri1 cfg_scl,cfg_sda;
    integer cfg_starts,cfg_stops,cfg_bytes;
    wire [31:0] cfg_packet;
    reg [3:0] cfg_ack_mask=4'hf;
    reg [23:0] expected[0:243];
    data_init #(.CNT_WAIT_MAX(16),.RESET_WAIT_MAX(80)) config_rom(
        .sys_clk(clk),.sys_rst_n(cfg_reset_n),.cfg_end(tx_done && !tx_error),
        .cfg_start(cfg_start),.cfg_data(cfg_data),.cfg_done(cfg_done));
    SCCB #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(80)) cfg_master(
        .clk(clk),.rst_n(cfg_reset_n),.sccb_start(cfg_start),.data_in(cfg_data),.sccb_read(1'b0),.read_data(),.error_code(),
        .SCL(cfg_scl),.SDA(cfg_sda),.sccb_done(tx_done),.sccb_error(tx_error),.busy(tx_busy));
    mini_sccb_slave_model cfg_slave(cfg_reset_n,cfg_scl,cfg_sda,cfg_ack_mask,
                                   cfg_starts,cfg_stops,cfg_bytes,cfg_packet);
    integer completed=0;
    reg golden_enabled=1;
    reg [63:0] cycles=0, last_complete_cycle=0;
    always @(posedge clk) cycles<=cycles+1;
    task check(input condition,input [511:0] label);
        begin
            checks=checks+1;
            if(condition!==1'b1) $fatal(1,"MINI_SCCB_FAIL: %0s",label);
        end
    endtask
    always @(posedge clk) if(cfg_reset_n && tx_done && golden_enabled) begin
        check(!tx_error,"configuration ACK success");
        check(completed<244,"no out-of-range configuration request");
        check(cfg_bytes==4,"exactly four wire bytes per register");
        check(cfg_packet==={8'h78,expected[completed]},"wire payload matches original register table");
        check(cfg_data[23:8]!=16'h300a && cfg_data[23:8]!=16'h300b,"no writes to read-only ID");
        completed=completed+1;
        last_complete_cycle=cycles;
    end
    // 软复位条目完成后，必须真的等待指定间隔，不能仅增加注释而仍然背靠背发送。
    always @(posedge clk) if(cfg_reset_n && cfg_start && completed==1 && golden_enabled)
        check(cycles-last_complete_cycle>=80,"software-reset wait honored");

    task issue(input [23:0] payload);
        begin @(negedge clk); data=payload; start=1; @(negedge clk); start=0; end
    endtask
    task reset_manual;
        begin
            reset_n=0; start=0; stretch=0; ack_mask=4'hf;
            repeat(8) @(negedge clk);
            reset_n=1; repeat(8) @(negedge clk);
        end
    endtask
    initial begin
        $readmemh("vendor_registers_244.hex",expected);
        reset_manual();
        check(scl===1'b1 && sda===1'b1,"reset releases both open-drain lines");
        issue(24'h1234a5);
        wait(busy); repeat(20) @(negedge clk);
        // 忙时更改输入并额外请求，当前事务仍必须发送最初锁存的四个字节。
        issue(24'hdeadbe);
        wait(done); #1;
        check(!error && !busy,"ACK transaction succeeds");
        check(packet===32'h781234a5 && bytes==4,"latched payload and byte order");
        check(starts==1 && stops==1,"one start/stop despite busy request");
        manual_cases=manual_cases+1;
        repeat(8) @(negedge clk);

        // 逐个字节注入 NACK，确保提前 STOP 且不会继续写后续寄存器字节。
        for(integer n=0;n<4;n=n+1) begin
            reset_manual(); ack_mask=4'hf ^ (4'b1<<n);
            issue(24'h300802); wait(done); #1;
            check(error && !busy,"NACK reports failure");
            check(bytes==n+1 && stops==1,"NACK aborts at selected byte");
            manual_cases=manual_cases+1;
        end
        reset_manual(); issue(24'h301700); wait(busy);
        @(negedge scl); stretch=1;
        wait(done); #1;
        check(error && !busy && sda===1'b1,"stuck SCL times out and releases SDA");
        stretch=0; repeat(8) @(negedge clk);
        check(scl===1'b1,"SCL is released after timeout");
        manual_cases=manual_cases+1;

        // 完整配置回归：244 条有效写，之后保持完成且不能产生第 245 条。
        cfg_reset_n=1;
        wait(cfg_done); repeat(200) @(negedge clk);
        check(completed==244 && cfg_starts==244 && cfg_stops==244,"exact configuration length");
        check(cfg_data===24'b0 && !tx_busy,"configuration completes without invalid ROM access");

        // 配置总线没有器件应答时，不允许 cfg_done 或后续配置请求伪成功。
        golden_enabled=0; cfg_reset_n=0; repeat(8) @(negedge clk);
        cfg_ack_mask=0; cfg_reset_n=1;
        wait(tx_done); repeat(300) @(negedge clk);
        check(tx_error && !cfg_done && cfg_starts==1,"NACK prevents configuration completion");
        $display("MINI_SCCB_RESULT checks=%0d manual_cases=%0d configuration_writes=%0d",checks,manual_cases,completed);
        $display("MINI_SCCB_PASS");
        $finish;
    end
    // 硬超时使挂起不能被当作成功退出。
    initial begin #10000000; $fatal(1,"MINI_SCCB_TIMEOUT"); end
endmodule
