`timescale 1ns/1ps
// Same port-level oracle is used for RTL, synthesis, and routed netlists.
module tb_flow_smoke;
    reg clk = 0;
    reg rstn = 0;
    reg key = 1;
    wire led0;
    flow_smoke_top dut(.clk(clk), .rstn(rstn), .key(key), .led0(led0));
    always #18.5185 clk = ~clk;

    integer cycle = 0;
    integer errors = 0;
    integer checks = 0;
    integer toggles = 0;
    integer active_cycles = 0;
    reg [1:0] reset_history = 0;
    reg [1:0] key_history = 3;
    reg expected = 0;
    reg previous_expected = 0;

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!reset_history[1]) begin
            active_cycles = 0;
            expected = 0;
        end else begin
            active_cycles = active_cycles + 1;
            if ((active_cycles % 32 == 0) && key_history[1])
                expected = ~expected;
        end
        reset_history = {reset_history[0], rstn};
        key_history = {key_history[0], key};
        // Allow routed clock-to-output delay, sample well before next edge.
        #12;
        if (cycle > 12) begin
            checks = checks + 1;
            if (led0 !== expected) begin
                $display("FLOW_MISMATCH cycle=%0d expected=%b actual=%b", cycle, expected, led0);
                errors = errors + 1;
            end
            if (expected != previous_expected) toggles = toggles + 1;
        end
        previous_expected = expected;
    end

    initial begin
        // Changes occur away from active edges; metastability is not simulated.
        repeat (20) @(negedge clk);
        rstn = 1;
        repeat (180) @(negedge clk);
        key = 0;
        repeat (90) @(negedge clk);
        key = 1;
        repeat (180) @(negedge clk);
        rstn = 0;
        repeat (10) @(negedge clk);
        rstn = 1;
        repeat (180) @(negedge clk);
        key = 0;
        repeat (70) @(negedge clk);
        key = 1;
        repeat (180) @(negedge clk);
        if ((errors == 0) && (checks > 800) && (toggles > 15))
            $display("FLOW_SIM_PASS checks=%0d toggles=%0d", checks, toggles);
        else
            $display("FLOW_SIM_FAIL errors=%0d checks=%0d toggles=%0d", errors, checks, toggles);
        $finish;
    end
    initial begin
        #100000;
        $display("FLOW_SIM_FAIL watchdog");
        $finish;
    end
endmodule
