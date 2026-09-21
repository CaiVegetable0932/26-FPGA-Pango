// Offline GMII regression. CSV captures accepted inputs and registered outputs
// separately so Python can reconstruct expected packets without using RTL CRC.
module tb_udp_ipv4_eth_tx;
    timeunit 1ns;
    timeprecision 1ps;
    parameter integer RX_TIMEOUT_CYCLES = 32;
    reg clk = 0;
    always #4 clk = ~clk;
    reg reset_n = 0;
    reg datagram_start = 0;
    wire datagram_ready;
    reg [15:0] udp_payload_length = 0;
    reg [47:0] src_mac = 0, dst_mac = 0;
    reg [31:0] src_ip = 0, dst_ip = 0;
    reg [15:0] src_port = 0, dst_port = 0;
    reg payload_valid = 0;
    wire payload_ready;
    reg [7:0] payload_data = 0;
    wire [7:0] gmii_txd;
    wire gmii_tx_en, gmii_tx_er, busy, done, error;
    integer cycle = 0, trace_file, i, n, serial = 0;
    integer error_count = 0, done_count = 0, expected_errors = 0;
    integer overlap_cycles = 0, start_wait_cycles = 0, phase = 0;
    integer observed_frame_bytes = 0;
    reg sampled_start_ready, sampled_payload_ready;
    reg [31:0] random_state = 32'h1729abcd;
    integer seed_arg;

    udp_ipv4_eth_tx #(.RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) dut (
        .clk(clk), .reset_n(reset_n),
        .datagram_start(datagram_start), .datagram_ready(datagram_ready),
        .udp_payload_length(udp_payload_length),
        .src_mac(src_mac), .dst_mac(dst_mac), .src_ip(src_ip), .dst_ip(dst_ip),
        .src_port(src_port), .dst_port(dst_port),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .busy(busy), .done(done), .error(error)
    );

    // Deterministic LCG stimulus is repeatable on the installed ModelSim 10.1c.
    function automatic integer random_mod(input integer modulus);
        begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            random_mod = (random_state >> 8) % modulus;
        end
    endfunction
    function automatic [7:0] pattern(input integer packet, input integer index);
        pattern = ((packet * 73 + index * 29) ^ (index >> 3) ^ (packet << 2)) & 255;
    endfunction

    // Capture ready before the edge and output after NBA. Inputs only change
    // on falling edges, removing driver/monitor/DUT scheduling ambiguity.
    always @(posedge clk) begin
        sampled_start_ready = datagram_ready;
        sampled_payload_ready = payload_ready;
        cycle = cycle + 1;
        #1;
        // Count external GMII bytes only, to align the directed bank handoff
        // without relying on an internal state name or implementation counter.
        if (gmii_tx_en) observed_frame_bytes = observed_frame_bytes + 1;
        else observed_frame_bytes = 0;
        if (trace_file != 0)
            $fdisplay(trace_file, "%0d,%0d,%0d,%0d,%0d,%012h,%012h,%08h,%08h,%04h,%04h,%0d,%0d,%02h,%0d,%02h,%0d,%0d,%0d,%0d,%0d",
                cycle, reset_n, datagram_start, sampled_start_ready,
                udp_payload_length, src_mac, dst_mac, src_ip, dst_ip, src_port, dst_port,
                payload_valid, sampled_payload_ready, payload_data,
                gmii_tx_en, gmii_txd, gmii_tx_er, busy, done, error, phase);
        if (gmii_tx_er !== 1'b0) $fatal(1, "UDP_ETH_FAIL tx_er");
        if (!reset_n && (gmii_tx_en || busy || done || error ||
                         datagram_ready || payload_ready))
            $fatal(1, "UDP_ETH_FAIL reset did not silence/flush");
        if (reset_n) begin
            if (error) error_count = error_count + 1;
            if (done) begin
                done_count = done_count + 1;
                if (!gmii_tx_en) $fatal(1, "UDP_ETH_FAIL done not on FCS");
            end
            if (sampled_payload_ready && payload_valid && gmii_tx_en)
                overlap_cycles = overlap_cycles + 1;
            if (datagram_start && !sampled_start_ready)
                start_wait_cycles = start_wait_cycles + 1;
        end
        if (cycle > 300000) $fatal(1, "UDP_ETH_TIMEOUT global watchdog");
    end

    // Metadata changes for every packet and is poisoned after acceptance to
    // exercise bank-local latching while a previous frame is still transmitting.
    task automatic begin_datagram(input integer length);
        integer waited;
        reg accepted;
        begin
            @(negedge clk);
            serial = serial + 1;
            udp_payload_length = length;
            src_mac = 48'h021122330000 + serial;
            dst_mac = 48'h025566770000 + serial * 3;
            src_ip = 32'hc0000201 + serial;
            dst_ip = 32'hc6336401 + serial * 5;
            src_port = 16'd50001 + serial;
            dst_port = 16'd50000 - serial;
            datagram_start = 1;
            accepted = 0;
            waited = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = datagram_ready;
                waited = waited + 1;
                #2;
                if (waited > 5000) $fatal(1, "UDP_ETH_FAIL start deadlock");
            end
            @(negedge clk);
            datagram_start = 0;
            udp_payload_length = 16'hffff;
            src_mac = ~src_mac; dst_mac = ~dst_mac;
            src_ip = ~src_ip; dst_ip = ~dst_ip;
            src_port = ~src_port; dst_port = ~dst_port;
        end
    endtask

    // Keep a valid byte stable until accepted; random source bubbles exercise
    // non-contiguous collection. GMII has no ready input and cannot be stalled.
    task automatic send_byte(input [7:0] value, input integer bubbles);
        integer gap, waited;
        reg accepted;
        begin
            for (gap = 0; gap < bubbles; gap = gap + 1) begin
                @(negedge clk); payload_valid = 0;
            end
            @(negedge clk);
            payload_valid = 1;
            payload_data = value;
            accepted = 0;
            waited = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = payload_ready;
                waited = waited + 1;
                #2;
                if (waited > RX_TIMEOUT_CYCLES + 5)
                    $fatal(1, "UDP_ETH_FAIL payload deadlock");
            end
        end
    endtask
    task automatic end_payload;
        begin @(negedge clk); payload_valid = 0; end
    endtask
    task automatic send_packet(input integer length, input integer random_gaps);
        integer k, gap;
        begin
            begin_datagram(length);
            for (k = 0; k < length; k = k + 1) begin
                gap = random_gaps ? random_mod(4) : 0;
                send_byte(pattern(serial, k), gap);
            end
            end_payload();
        end
    endtask
    task automatic wait_idle;
        integer waited;
        begin
            waited = 0;
            while (busy) begin
                @(posedge clk); #2;
                waited = waited + 1;
                if (waited > 6000) $fatal(1, "UDP_ETH_FAIL drain deadlock");
            end
            repeat (3) begin @(posedge clk); #2; end
        end
    endtask
    task automatic reset_dut;
        begin
            @(negedge clk);
            reset_n = 0; datagram_start = 0; payload_valid = 0;
            repeat (4) @(negedge clk);
            reset_n = 1;
        end
    endtask
    task automatic expect_timeout;
        integer old_errors;
        begin
            old_errors = error_count;
            end_payload();
            repeat (RX_TIMEOUT_CYCLES + 3) begin @(posedge clk); #2; end
            expected_errors = expected_errors + 1;
            if (error_count != old_errors + 1)
                $fatal(1, "UDP_ETH_FAIL timeout count");
        end
    endtask

    // Directed boundaries, bank overlap, invalid lengths, reset flush, stalled
    // collection, deadline recovery and a saturated 16-packet throughput burst.
    initial begin
        trace_file = $fopen("gmii_trace.csv", "w");
        if (!trace_file) $fatal(1, "UDP_ETH_FAIL cannot open trace");
        $fdisplay(trace_file, "cycle,reset_n,start,start_ready,length,src_mac,dst_mac,src_ip,dst_ip,src_port,dst_port,valid,payload_ready,data,tx_en,tx_data,tx_er,busy,done,error,phase");
        if ($value$plusargs("SEED=%d", seed_arg)) random_state = seed_arg;
        if (RX_TIMEOUT_CYCLES < 8) $fatal(1, "UDP_ETH_FAIL test requires timeout >=8");
        reset_dut();

        // Stray payload while idle is ignored, and invalid starts produce only
        // error, never a partial Ethernet frame or an allocated receive bank.
        @(negedge clk); payload_valid = 1; payload_data = 8'hee;
        repeat (4) @(negedge clk);
        payload_valid = 0;
        begin_datagram(0); expected_errors = expected_errors + 1;
        begin_datagram(1465); expected_errors = expected_errors + 1;
        begin_datagram(65535); expected_errors = expected_errors + 1;
        wait_idle();
        if (done_count != 0 || error_count != expected_errors)
            $fatal(1, "UDP_ETH_FAIL bad length emitted frame");

        send_packet(1, 0); send_packet(2, 1);
        send_packet(17, 1); send_packet(18, 0); send_packet(19, 1);
        send_packet(65, 1); send_packet(1463, 1); send_packet(1464, 1);
        for (i = 0; i < 16; i = i + 1) begin
            n = 1 + random_mod(1464);
            send_packet(n, 1);
        end
        wait_idle();

        // No first byte, then missing suffix, then a timeout concurrent with
        // another bank's uninterrupted maximum-size transmission.
        begin_datagram(64); expect_timeout(); wait_idle();
        begin_datagram(64);
        for (i = 0; i < 9; i = i + 1) send_byte(pattern(serial, i), 0);
        expect_timeout(); wait_idle();
        send_packet(1464, 0);
        begin_datagram(64); expect_timeout();
        send_packet(65, 0); wait_idle();

        // Exactly limit-1 empty receive clocks followed by a handshake on the
        // deadline must succeed; repeat after one byte to test timer restart.
        begin_datagram(2);
        repeat (RX_TIMEOUT_CYCLES - 1) begin @(posedge clk); #2; end
        send_byte(8'h00, 0);
        end_payload();
        repeat (RX_TIMEOUT_CYCLES - 1) begin @(posedge clk); #2; end
        send_byte(8'hff, 0);
        end_payload(); wait_idle();

        // Complete receive bank B on exactly the same edge as bank A's final
        // FCS. Both ownership flags must update, preserving the queued packet.
        send_packet(1464, 0);
        while (observed_frame_bytes < 1513) begin @(posedge clk); #2; end
        begin_datagram(1);
        while (observed_frame_bytes < 1517) begin @(posedge clk); #2; end
        send_byte(8'ha5, 0);
        end_payload();
        send_packet(2, 0); wait_idle();

        // Reset an incomplete receive (no wire frame), then reset while one
        // frame is active and another is queued. Only reset may truncate GMII.
        phase = 2;
        begin_datagram(128);
        for (i = 0; i < 7; i = i + 1) send_byte(pattern(serial, i), 0);
        end_payload(); reset_dut(); wait_idle();
        send_packet(1464, 0); send_packet(1, 0);
        repeat (20) begin @(posedge clk); #2; end
        reset_dut(); wait_idle();
        send_packet(19, 0); wait_idle();

        // No source bubbles in this phase: steady-state frame start intervals
        // include all wire bytes and IFG, so Python measures useful throughput.
        phase = 1;
        for (i = 0; i < 16; i = i + 1) send_packet(1464, 0);
        wait_idle();
        phase = 0;
        if (error_count != expected_errors)
            $fatal(1, "UDP_ETH_FAIL unexpected error count %0d expected %0d", error_count, expected_errors);
        if (overlap_cycles < 1000 || start_wait_cycles == 0)
            $fatal(1, "UDP_ETH_FAIL missing bank overlap/backpressure coverage");
        $display("UDP_ETH_PASS done=%0d errors=%0d overlap=%0d start_wait=%0d timeout=%0d seed=%08h",
                 done_count, error_count, overlap_cycles, start_wait_cycles, RX_TIMEOUT_CYCLES, seed_arg);
        $fclose(trace_file);
        $finish;
    end
endmodule
