`timescale 1ns/1ps
// Purpose: native PDS OSERDES model regression of the current shared lane.
// Exhaustively tests repeated symbols and reset recovery with native /5 clocks.
// clocks. Not a physical board test or a full variable-symbol stream test.
module tb_hdmi_native;
    reg serial_clk = 0, async_reset_n = 0, global_reset_n = 0;
    reg [9:0] symbol = 0;
    wire pixel_clk, divider_reset_n;
    wire pixel_reset_n;
    wire data_p, data_n;
    integer checks = 0, errors = 0, symbols_checked = 0;
    integer phase = -1, candidate, value;
    reg [19:0] captured;
    reg [19:0] captured1, captured2, captured_clock;
    wire data1_p, data1_n, data2_p, data2_n, clock_p, clock_n;
    reg finished = 0;
    real edge_start, high_time, period_time;

    // Exercise the actual native divider: five serial periods per pixel,
    // including the documented two-high/three-low (40%) pixel duty cycle.
    always #1.347 serial_clk = ~serial_clk;
    GTP_GRS GRS_INST(.GRS_N(global_reset_n));
    reset_sync u_divider_reset(serial_clk, async_reset_n, divider_reset_n);
    GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_pixel_divider(
        .CLKIN(serial_clk), .CE(1'b1), .RST_N(divider_reset_n), .CLKDIVOUT(pixel_clk));
    // Use the real common power-up hold and per-lane rising-pixel release.
    hdmi_tx_powerup_reset #(.HOLD_BITS(4)) u_powerup(
        pixel_clk, async_reset_n, pixel_reset_n);
    hdmi_tx_oserdes u_dut(pixel_clk, serial_clk, pixel_reset_n, symbol, data_p, data_n);
    // Distinct lane signatures must use the SAME serial phase before/after reset.
    hdmi_tx_oserdes u_lane1(pixel_clk, serial_clk, pixel_reset_n, symbol^10'h155, data1_p, data1_n);
    hdmi_tx_oserdes u_lane2(pixel_clk, serial_clk, pixel_reset_n, symbol^10'h2aa, data2_p, data2_n);
    hdmi_tx_oserdes u_clock(pixel_clk, serial_clk, pixel_reset_n, 10'b1111100000, clock_p, clock_n);

    // 明确累计检查与失败数，X/Z 不作为有效输出；只有完成标记和零失败同时满足才算通过。
    task check;
        input condition;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                if (errors <= 20) $display("TMDS_CHECK_FAILED time=%0t symbol=%03h label=%0s", $time, symbol, label);
            end
        end
    endtask

    // 恒定符号流没有外部字边界标记：仅在开始时校准一次采样偏移，后续所有向量固定使用此偏移。
    function [9:0] rotate_symbol;
        input [9:0] data;
        input integer offset;
        begin rotate_symbol = (data >> offset) | (data << (10-offset)); end
    endfunction

    // 每个符号先稳定 16 个像素周期，再连续采集两组十位；不依据 DUT 内部数据选择比较期望值。
    task capture_symbol;
        input [9:0] next_symbol;
        output [19:0] data;
        integer bit_number;
        begin
            @(negedge pixel_clk); symbol = next_symbol;
            repeat (16) @(posedge pixel_clk);
            for (bit_number = 0; bit_number < 20; bit_number = bit_number + 1) begin
                @(serial_clk); #0.03;
                data[bit_number] = data_p;
                captured1[bit_number] = data1_p;
                captured2[bit_number] = data2_p;
                captured_clock[bit_number] = clock_p;
                check(data_n === ~data_p && (data_p === 1'b0 || data_p === 1'b1), "known complementary differential output");
                check(data1_n === ~data1_p && data2_n === ~data2_p && clock_n === ~clock_p, "other differential lanes");
            end
        end
    endtask

    initial begin
        #100; global_reset_n = 1; async_reset_n = 1;
        wait (pixel_reset_n === 1'b1);
        repeat (8) @(posedge pixel_clk);

        // Check the actual native divider duty, not an idealized 50% clock.
        @(posedge pixel_clk); edge_start = $realtime;
        @(negedge pixel_clk); high_time = $realtime - edge_start;
        @(posedge pixel_clk); period_time = $realtime - edge_start;
        check(period_time > 13.46 && period_time < 13.48, "pixel clock period");
        check(high_time/period_time > 0.399 && high_time/period_time < 0.401, "pixel clock 40 percent duty");

        capture_symbol(10'b0000101101, captured);
        for (candidate = 0; candidate < 10; candidate = candidate + 1)
            if (captured[9:0] === rotate_symbol(10'b0000101101, candidate)) phase = candidate;
        check(phase >= 0, "single fixed serial sampling phase");
        if (phase < 0) $fatal(1, "TMDS_PHASE_FAILED");
        for (value = 0; value < 1024; value = value + 1) begin
            capture_symbol(value[9:0], captured);
            check(captured[9:0] === rotate_symbol(value[9:0], phase), "first complete symbol mapping");
            check(captured[19:10] === rotate_symbol(value[9:0], phase), "second complete symbol mapping");
            check(captured1 === {2{rotate_symbol(value[9:0]^10'h155, phase)}}, "lane1 same phase");
            check(captured2 === {2{rotate_symbol(value[9:0]^10'h2aa, phase)}}, "lane2 same phase");
            check(captured_clock === {2{rotate_symbol(10'b1111100000, phase)}}, "forwarded clock same phase");
            symbols_checked = symbols_checked + 1;
        end

        // 再次异步复位并重启同源分频/像素复位链，校验固定采样相位下的数据可恢复。
        #0.37; async_reset_n = 0; #100; async_reset_n = 1;
        wait (pixel_reset_n === 1'b1);
        capture_symbol(10'b1101010100, captured);
        check(captured[9:0] === rotate_symbol(10'b1101010100, phase), "symbol after reset recovery");
        check(captured1 === {2{rotate_symbol(10'b1101010100^10'h155, phase)}}, "lane1 reset recovery");
        check(captured2 === {2{rotate_symbol(10'b1101010100^10'h2aa, phase)}}, "lane2 reset recovery");
        check(captured_clock === {2{rotate_symbol(10'b1111100000, phase)}}, "clock reset recovery");
        finished = 1;
        $display("TMDS_RESULT checks=%0d errors=%0d symbols=%0d phase=%0d period_ns=%0.4f high_ns=%0.4f", checks, errors, symbols_checked, phase, period_time, high_time);
        if (errors != 0) $fatal(1, "TMDS_FAILED");
        $display("TMDS_PASS");
        $finish;
    end

    // 硬超时区分仿真未完成与真正通过，避免因时钟/复位卡住而误报成功。
    initial begin #500000; if (!finished) $fatal(1, "TMDS_TIMEOUT"); end
endmodule
