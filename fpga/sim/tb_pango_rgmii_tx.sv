`timescale 1ns/1ps

// Purpose: test the native PDS ODDR and GRS models, with no primitive stubs.
// The independent scoreboard checks continuous traffic with the installed
// SAME_EDGE one-cycle latency, all byte/control pairs, and reset recovery.
module tb_pango_rgmii_tx;
    reg clk125 = 0, clk125_90 = 0;
    reg reset_n = 0, global_reset_n = 0;
    reg [7:0] gmii_data = 0;
    reg gmii_en = 0, gmii_error = 0;
    wire rgmii_txc, rgmii_ctl;
    wire [3:0] rgmii_data;
    integer checks = 0, errors = 0, vectors = 0;
    integer txc_rises = 0, txc_falls = 0;
    integer local_resets = 0, global_resets = 0;
    integer coverage [0:2][0:3][0:255];
    integer epoch, control, value, phase;
    integer input_epoch = -1, pending_epoch = -1, active_epoch = -1;
    reg [7:0] pending_data = 0, active_data = 0;
    reg pending_en = 0, pending_error = 0;
    reg active_en = 0, active_error = 0, observed_rising_ctl = 0;
    reg clock_primed = 0, expected_clock_high = 0;
    reg have_txc_rise = 0, finished = 0;
    real last_data_rise = -100.0, last_data_fall = -100.0;
    real last_txc_rise = -100.0;

    // Ideal board-PLL stimulus only: 8 ns period, shifted clock LAGS by 2 ns.
    // This verifies the adapter's phase contract, not a PLL or physical skew.
    always #4 clk125 = ~clk125;
    initial begin #2; forever #4 clk125_90 = ~clk125_90; end

    // PDS models resolve this exact GRS_INST instance name hierarchically.
    // GTP_GRS itself is compiled directly from the installed official source.
    GTP_GRS GRS_INST (.GRS_N(global_reset_n));
    pango_rgmii_tx dut (
        .clk125(clk125), .clk125_90(clk125_90), .reset_n(reset_n),
        .gmii_data(gmii_data), .gmii_en(gmii_en), .gmii_error(gmii_error),
        .rgmii_txc(rgmii_txc), .rgmii_ctl(rgmii_ctl), .rgmii_data(rgmii_data)
    );

    // Four-state comparisons reject X/Z; keep failures readable but never
    // stop counting them or allow a missing completion marker to pass.
    task automatic check(input condition, input string label_text);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("RGMII_TX_CHECK_FAILED t=%0t %0s data=%h ctl=%b txc=%b",
                             $time, label_text, rgmii_data, rgmii_ctl, rgmii_txc);
            end
        end
    endtask

    // Source-side queue: only GMII inputs determine expectations, never DUT
    // internals. A reset empties both the sampled and currently emitted word.
    always @(posedge clk125 or negedge reset_n or negedge global_reset_n) begin
        if (!reset_n || !global_reset_n) begin
            pending_data = 0; pending_en = 0; pending_error = 0;
            active_data = 0; active_en = 0; active_error = 0;
            pending_epoch = -1; active_epoch = -1;
        end else begin
            active_data = pending_data; active_en = pending_en;
            active_error = pending_error; active_epoch = pending_epoch;
            pending_data = gmii_data; pending_en = gmii_en;
            pending_error = gmii_error; pending_epoch = input_epoch;
        end
    end

    // Check data launch edges, including the empty first pipeline cycle.
    // Sample after NBA settling; the reference edge times remain exact.
    always @(posedge clk125) begin
        last_data_rise = $realtime;
        #0.05;
        if (reset_n && global_reset_n) begin
            check(rgmii_data === active_data[3:0], "rising low nibble / one-cycle latency");
            check(rgmii_ctl === active_en, "rising TX_EN");
            check(rgmii_txc === 1'b0, "TXC still low at data rising launch");
            observed_rising_ctl = rgmii_ctl;
        end else begin
            check({rgmii_data, rgmii_ctl, rgmii_txc} === 6'b0, "held reset rising");
        end
    end

    // Credit a vector only after BOTH nibble/control halves have been checked.
    // Decoding the two observed CTL levels must recover the sampled TX_ER.
    always @(negedge clk125) begin
        last_data_fall = $realtime;
        #0.05;
        if (reset_n && global_reset_n) begin
            check(rgmii_data === active_data[7:4], "falling high nibble from same sample");
            check(rgmii_ctl === (active_en ^ active_error), "falling TX_EN XOR TX_ER");
            check((observed_rising_ctl ^ rgmii_ctl) === active_error, "dual-edge TX_ER decode");
            check(rgmii_txc === expected_clock_high, "TXC level before shifted falling edge");
            if (active_epoch >= 0) begin
                coverage[active_epoch][{active_error, active_en}][active_data] =
                    coverage[active_epoch][{active_error, active_en}][active_data] + 1;
                vectors = vectors + 1;
            end
        end else begin
            check({rgmii_data, rgmii_ctl, rgmii_txc} === 6'b0, "held reset falling");
        end
    end

    // The clock ODDR also needs one rising-edge sample before output starts.
    // Explicitly check the first zero cycle and every subsequent 1/0 pair.
    always @(posedge clk125_90 or negedge reset_n or negedge global_reset_n) begin
        if (!reset_n || !global_reset_n) begin
            clock_primed = 0; expected_clock_high = 0;
        end else begin
            expected_clock_high = clock_primed;
            clock_primed = 1;
            check(($realtime - last_data_rise) == 2.0, "PLL stimulus rising phase is +2 ns");
            #0.05;
            check(rgmii_txc === expected_clock_high, "clock ODDR rising and reset warm-up");
        end
    end

    // Every shifted falling edge must drive zero, including startup/reset.
    always @(negedge clk125_90) begin
        check(($realtime - last_data_fall) == 2.0, "PLL stimulus falling phase is +2 ns");
        #0.05;
        check(rgmii_txc === 1'b0, "clock ODDR falling zero");
    end

    // Measure actual TXC pin transitions so missing, early or extra edges,
    // wrong duty cycle, and a direct unshifted clk125 connection are detected.
    always @(posedge rgmii_txc or negedge reset_n or negedge global_reset_n) begin
        if (!reset_n || !global_reset_n) begin
            have_txc_rise = 0;
        end else begin
            check(rgmii_txc === 1'b1 && clk125_90 === 1'b1, "TXC rise follows shifted clock");
            check(($realtime - last_data_rise) == 2.0, "actual TXC rising phase is +90 degrees");
            if (have_txc_rise)
                check(($realtime - last_txc_rise) == 8.0, "actual TXC period is 8 ns");
            last_txc_rise = $realtime; have_txc_rise = 1;
            txc_rises = txc_rises + 1;
        end
    end

    // An asynchronous reset may truncate a pulse; normal pulses must be 4 ns.
    always @(negedge rgmii_txc) begin
        if (reset_n && global_reset_n && have_txc_rise) begin
            check(rgmii_txc === 1'b0 && clk125_90 === 1'b0, "TXC fall follows shifted clock");
            check(($realtime - last_data_fall) == 2.0, "actual TXC falling phase is +90 degrees");
            check(($realtime - last_txc_rise) == 4.0, "actual TXC high width is 4 ns");
            txc_falls = txc_falls + 1;
        end
    end

    // Drive a new byte every cycle, then deliberately corrupt data and EN
    // after the capture edge. SAME_EDGE must ignore this falling-edge bait;
    // an OPPOSITE_EDGE instance or live D1 wiring will fail the scoreboard.
    task automatic send_vector(input [7:0] data_value, input en_value,
                               input error_value, input integer epoch_value);
        begin
            @(negedge clk125); #0.2;
            gmii_data = data_value; gmii_en = en_value;
            gmii_error = error_value; input_epoch = epoch_value;
            @(posedge clk125); #0.5;
            gmii_data = ~data_value; gmii_en = ~en_value;
        end
    endtask

    // Cover each byte with every EN/ER pair while varying controls on every
    // cycle. Drain the queue before resets or coverage assertions.
    task automatic run_sweep(input integer epoch_value);
        integer rotation, byte_value, control_value;
        begin
            for (rotation = 0; rotation < 4; rotation = rotation + 1)
                for (byte_value = 0; byte_value < 256; byte_value = byte_value + 1) begin
                    control_value = (byte_value + rotation) % 4;
                    send_vector(byte_value[7:0], control_value[0], control_value[1], epoch_value);
                end
            @(negedge clk125); #0.2;
            gmii_data = 0; gmii_en = 0; gmii_error = 0; input_epoch = -1;
            repeat (3) @(posedge clk125);
            @(negedge clk125); #0.2;
            $display("RGMII_TX_SWEEP epoch=%0d completed_vectors=%0d", epoch_value, vectors);
        end
    endtask

    // The three exhaustive sweeps prove initial operation, local-reset
    // recovery, and independent global-reset recovery using identical checks.
    initial begin
        for (epoch = 0; epoch < 3; epoch = epoch + 1)
            for (control = 0; control < 4; control = control + 1)
                for (value = 0; value < 256; value = value + 1)
                    coverage[epoch][control][value] = 0;
        #1;
        check({rgmii_data, rgmii_ctl, rgmii_txc} === 6'b0, "initial reset levels");
        #18; global_reset_n = 1; reset_n = 1;
        run_sweep(0);

        // Assert local RS in each quadrant relative to the two clocks.
        // Fill the pipeline with ones first so clearing zero is meaningful.
        for (phase = 0; phase < 4; phase = phase + 1) begin
            repeat (3) send_vector(8'hff, 1'b1, 1'b0, -1);
            @(posedge clk125); #(0.7 + phase * 2.0);
            reset_n = 0; local_resets = local_resets + 1;
            repeat (2) @(negedge clk125_90);
            #0.7; reset_n = 1;
            // Releases occur with both clocks low; every startup edge is
            // still checked, not skipped until a convenient steady state.
            repeat (3) send_vector(8'h3c, 1'b1, 1'b1, -1);
        end
        run_sweep(1);

        // Exercise GRS independently, while local reset remains released.
        repeat (3) send_vector(8'hff, 1'b1, 1'b0, -1);
        @(posedge clk125_90); #0.7;
        global_reset_n = 0; global_resets = global_resets + 1;
        repeat (2) @(negedge clk125_90);
        #0.7; global_reset_n = 1;
        run_sweep(2);

        // Exact coverage prevents a shortened loop, duplicate-only traffic,
        // reset-discarded vectors, or a premature finish from being a PASS.
        for (epoch = 0; epoch < 3; epoch = epoch + 1)
            for (control = 0; control < 4; control = control + 1)
                for (value = 0; value < 256; value = value + 1)
                    check(coverage[epoch][control][value] == 1,
                          $sformatf("coverage epoch=%0d control=%0d byte=%0d", epoch, control, value));
        check(vectors == 3072, "three complete 256-byte by four-control sweeps");
        check(local_resets == 4 && global_resets == 1, "all requested reset phases completed");
        check(txc_rises > 3072 && txc_falls > 3072, "forwarded clock edge checks ran");
        finished = 1;
        $display("RGMII_TX_RESULT checks=%0d errors=%0d vectors=%0d local_resets=%0d global_resets=%0d txc_rises=%0d txc_falls=%0d",
                 checks, errors, vectors, local_resets, global_resets, txc_rises, txc_falls);
        if (errors != 0) $fatal(1, "RGMII_TX_FAILED");
        $display("RGMII_TX_PASS");
        $finish;
    end

    // A finite simulated-time bound catches a lost clock or stalled stimulus.
    initial begin #100000; if (!finished) $fatal(1, "RGMII_TX_TIMEOUT"); end

    // Check asynchronous assertion between clock edges for both local RS and
    // official global GRS; waiting a clock edge here would hide sync-only bugs.
    always @(negedge reset_n or negedge global_reset_n) begin
        #0.05;
        check({rgmii_data, rgmii_ctl, rgmii_txc} === 6'b0, "asynchronous reset clears every pin");
    end
endmodule
