`timescale 1ns/1ps
// 模块用途：tb_board_io 自检复位同步器和 RGMII 物理封装，使用本机 PDS 原生 GTP 行为模型。
// 覆盖 2/3/4 级复位链、异步复位相位/停钟，以及全部字节与 RX_CTL/TX_CTL 组合。
// 边界：这是 RTL 单元仿真，不连接真实 PHY，不验证 MAC、板级延时、网络吞吐或 DDR。
module tb_board_io;
    reg reset_clk = 0, reset_clock_enabled = 1, async_reset_n = 0;
    wire reset2_n, reset3_n, reset4_n;
    integer checks = 0, errors = 0, tx_cases = 0, rx_cases = 0;
    integer phase, stage, value, control;
    reg finished = 0;

    // 独立的复位测试时钟可暂停，验证没有时钟时仍能置复位、但不能提前解除复位。
    always #5 if (reset_clock_enabled) reset_clk = ~reset_clk;
    reset_sync #(.STAGES(2)) u_reset2(reset_clk, async_reset_n, reset2_n);
    reset_sync #(.STAGES(3)) u_reset3(reset_clk, async_reset_n, reset3_n);
    reset_sync #(.STAGES(4)) u_reset4(reset_clk, async_reset_n, reset4_n);

    // TX/RX 都采用 125 MHz、不同相位；全局复位实例名称遵循 PDS 原生仿真模型的要求。
    reg tx_clk = 0, rx_clock_input = 0, rx_clock_enabled = 1, global_reset_n = 0, io_reset = 1;
    reg [7:0] tx_data = 0;
    reg tx_valid = 0;
    reg [3:0] rx_nibble = 0;
    reg rx_control = 0;
    wire rx_clk, rx_valid, rx_error, tx_clock_pin, tx_control_pin;
    wire [7:0] rx_data;
    wire [3:0] tx_nibble;
    always #4 tx_clk = ~tx_clk;
    initial begin #1.3; forever #4 if(rx_clock_enabled) rx_clock_input = ~rx_clock_input; end
    GTP_GRS GRS_INST(.GRS_N(global_reset_n));
    rgmii_phy_io u_rgmii(.tx_clk(tx_clk), .reset(io_reset), .tx_data(tx_data), .tx_valid(tx_valid),
        .rgmii_rxc(rx_clock_input), .rgmii_rxd(rx_nibble), .rgmii_rx_ctl(rx_control),
        .rx_clk(rx_clk), .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error),
        .rgmii_txc(tx_clock_pin), .rgmii_txd(tx_nibble), .rgmii_tx_ctl(tx_control_pin));

    // 用四态比较结果驱动自检；X/Z 不会被当作成功，失败数与完成标记共同决定结论。
    task check;
        input condition;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("CHECK_FAILED time=%0t label=%0s", $time, label);
            end
        end
    endtask

    // 接收端直接施加协议两沿值；按 SAME_PIPELINED 的一拍延迟检查字节、有效位与错误位。
    task receive_byte;
        input [7:0] data;
        input valid_bit, error_bit;
        begin
            @(negedge rx_clock_input); #0.2;
            rx_nibble = data[3:0]; rx_control = valid_bit;
            @(posedge rx_clock_input); #0.2;
            rx_nibble = data[7:4]; rx_control = valid_bit ^ error_bit;
            @(negedge rx_clock_input); #0.2;
            rx_nibble = 0; rx_control = 0;
            @(posedge rx_clock_input); #0.2;
            check(rx_data === data, "RX byte ordering");
            check(rx_valid === valid_bit, "RX valid decode");
            check(rx_error === error_bit, "RX error decode");
            rx_cases = rx_cases + 1;
        end
    endtask

    initial begin
        // 改变复位解除相位，逐个时钟检查三种同步级数，避免只测最终稳定电平。
        #0.1; async_reset_n = 1; #0.1; async_reset_n = 0;
        for (phase = 1; phase <= 16; phase = phase + 1) begin
            @(negedge reset_clk); #0.17;
            async_reset_n = 0; #0.05;
            check({reset4_n,reset3_n,reset2_n} === 3'b000, "asynchronous reset assertion");
            #(phase * 0.13); async_reset_n = 1;
            for (stage = 1; stage <= 4; stage = stage + 1) begin
                @(posedge reset_clk); #0.05;
                check(reset2_n === (stage >= 2), "STAGES=2 release latency");
                check(reset3_n === (stage >= 3), "STAGES=3 release latency");
                check(reset4_n === (stage >= 4), "STAGES=4 release latency");
            end
        end
        @(negedge reset_clk); reset_clock_enabled = 0;
        #0.17; async_reset_n = 0; #0.05;
        check({reset4_n,reset3_n,reset2_n} === 3'b000, "reset assertion with clock stopped");
        async_reset_n = 1; #27;
        check({reset4_n,reset3_n,reset2_n} === 3'b000, "no release without clock edges");
        reset_clock_enabled = 1;
        repeat (4) @(posedge reset_clk);
        #0.05; check({reset4_n,reset3_n,reset2_n} === 3'b111, "release after clock resumes");

        // 原生 GRS 和本地复位先覆盖两沿，再释放；待 ODDR 流水稳定后检查全部字节/有效位。
        global_reset_n = 1;
        repeat (4) @(posedge tx_clk);
        @(negedge tx_clk); #0.2; io_reset = 0;
        // The local TX reset chain releases after three edges; synchronous
        // primitive sampling begins on the following edge, with no early TXC.
        // The native SAME_EDGE model then transfers D0 at a falling edge,
        // making the forwarded rising clock observable at edge five.
        repeat (3) begin
            @(posedge tx_clk); #0.2;
            check({tx_nibble,tx_control_pin,tx_clock_pin} === 6'b0, "TX local reset release barrier");
        end
        repeat (2) @(posedge tx_clk); #0.2;
        check(tx_clock_pin === 1'b1, "TX forwarded clock after local release");
        for (control = 0; control < 2; control = control + 1) begin
            for (value = 0; value < 256; value = value + 1) begin
                @(negedge tx_clk); #0.2;
                tx_data = value; tx_valid = control;
                repeat (3) @(posedge tx_clk);
                #0.2;
                check(tx_nibble === tx_data[3:0], "TX rising low nibble");
                check(tx_control_pin === tx_valid, "TX rising control");
                check(tx_clock_pin === 1'b1, "TX forwarded rising clock");
                @(negedge tx_clk); #0.2;
                check(tx_nibble === tx_data[7:4], "TX falling high nibble");
                check(tx_control_pin === tx_valid, "TX falling control");
                check(tx_clock_pin === 1'b0, "TX forwarded falling clock");
                tx_cases = tx_cases + 1;
            end
        end

        // 包含无效字节和接收错误组合，不把 RX_CTL 的两沿错误地等同为同一有效信号。
        for (control = 0; control < 4; control = control + 1)
            for (value = 0; value < 256; value = value + 1)
                receive_byte(value[7:0], control[0], control[1]);

        // Establish a live RX_VALID, stop RXC, then request reset. IDDR itself
        // is synchronous, so the wrapper must suppress the stale valid/error.
        receive_byte(8'ha5, 1'b1, 1'b1);
        rx_clock_enabled = 0;
        #0.37; io_reset = 1; #0.2;
        check({tx_nibble,tx_control_pin,tx_clock_pin} === 6'b0, "TX asynchronous reset");
        check({rx_valid,rx_error} === 2'b0, "RX stopped-clock reset masks validity");
        io_reset = 0; #30;
        check({rx_valid,rx_error} === 2'b0, "RX cannot release without RXC");
        rx_clock_enabled = 1;
        repeat (3) begin
            @(posedge rx_clock_input); #0.2;
            check({rx_valid,rx_error} === 2'b0, "RX primitive reset held during release chain");
        end
        receive_byte(8'h5a, 1'b1, 1'b0);
        // Non-edge reset again checks both the asynchronous TX bank and the
        // locally held synchronous RX bank after clocks have resumed.
        #0.37; io_reset = 1; #0.2;
        repeat (3) @(posedge rx_clock_input);
        #0.2; check({rx_data,rx_valid,rx_error} === 10'b0, "RX synchronous reset");
        finished = 1;
        $display("BOARD_IO_RESULT checks=%0d errors=%0d tx_cases=%0d rx_cases=%0d", checks, errors, tx_cases, rx_cases);
        if (errors != 0) $fatal(1, "BOARD_IO_FAILED");
        $display("BOARD_IO_PASS");
        $finish;
    end

    // 硬超时避免失去时钟或测试未结束时被运行器误判为通过。
    initial begin #100000; if (!finished) $fatal(1, "BOARD_IO_TIMEOUT"); end
endmodule
