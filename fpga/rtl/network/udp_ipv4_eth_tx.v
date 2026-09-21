`timescale 1ns / 1ps
// Two-bank store-and-forward UDP/IPv4/Ethernet II transmitter, 125 MHz GMII.
// Static peer metadata only: no ARP, DHCP, PHY management, RGMII or CDC logic.
// Metadata is sampled on datagram_start && datagram_ready; payload transfers
// start on subsequent clocks. ready is independent of busy (which includes IFG).
// RX timeout counts consecutive clocks without a payload handshake (>=1).
// Invalid length/timeout pulses error and discards only the incomplete packet.
// done coincides with the final FCS byte. Reset flushes both banks and silences
// GMII immediately; resetting mid-frame necessarily truncates that wire frame.
module udp_ipv4_eth_tx #(
    parameter integer RX_TIMEOUT_CYCLES = 125000 // 1 ms; zero clamps to one clock
) (
    input  wire        clk, reset_n,
    input  wire        datagram_start,
    output wire        datagram_ready,
    input  wire [15:0] udp_payload_length,
    input  wire [47:0] src_mac, dst_mac,
    input  wire [31:0] src_ip, dst_ip,
    input  wire [15:0] src_port, dst_port,
    input  wire        payload_valid,
    output wire        payload_ready,
    input  wire [7:0]  payload_data,
    output reg  [7:0]  gmii_txd,
    output reg         gmii_tx_en,
    output wire        gmii_tx_er,
    output wire        busy,
    output reg         done, error
);
    // Verilog-2001 constant-width helper, including the one-clock boundary.
    function integer counter_width;
        input integer count;
        integer v;
        begin
            v = count - 1;
            counter_width = 0;
            while (v > 0) begin
                counter_width = counter_width + 1;
                v = v >> 1;
            end
            if (counter_width == 0) counter_width = 1;
        end
    endfunction
    localparam integer TIMEOUT_LIMIT = (RX_TIMEOUT_CYCLES < 1) ? 1 : RX_TIMEOUT_CYCLES;
    localparam integer TIMEOUT_WIDTH = counter_width(TIMEOUT_LIMIT);
    localparam [2:0] TX_IDLE = 3'd0, TX_PREAMBLE = 3'd1,
                     TX_BODY = 3'd2, TX_FCS = 3'd3, TX_IFG = 3'd4;

    // The receive pointer advances only on a complete packet, the transmit
    // pointer only on final FCS. Full remains asserted during transmission to
    // prevent overwrite. Timeout reuses its bank, leaving no hole in the queue.
    reg [1:0] bank_full;
    reg rx_bank, tx_bank, rx_active;
    reg [10:0] rx_count;
    reg [TIMEOUT_WIDTH-1:0] rx_idle_count;
    reg [47:0] bank_src_mac [0:1], bank_dst_mac [0:1];
    reg [31:0] bank_src_ip [0:1], bank_dst_ip [0:1];
    reg [15:0] bank_src_port [0:1], bank_dst_port [0:1];
    reg [15:0] bank_length [0:1], bank_ip_length [0:1];
    reg [15:0] bank_udp_length [0:1], bank_body_length [0:1];
    reg [15:0] bank_ip_checksum [0:1];
    reg [2:0] tx_state, preamble_index;
    reg [10:0] body_index;
    reg [1:0] fcs_index;
    reg [3:0] ifg_count;
    reg [31:0] crc_state;
    integer bank_reset_index;

    assign datagram_ready = reset_n && !rx_active && !bank_full[rx_bank];
    assign payload_ready = reset_n && rx_active;
    assign gmii_tx_er = 1'b0;
    assign busy = reset_n && (rx_active || (|bank_full) || tx_state != TX_IDLE);

    // IPv4: IHL=5, DSCP/ECN=0, ID=0, DF=1, offset=0, TTL=64, protocol=17.
    // Balanced partial sums and end-around carry form the header checksum.
    // ID zero is used only with atomic (DF, non-fragmented) datagrams.
    function [15:0] ipv4_checksum;
        input [15:0] length;
        input [31:0] source_ip, destination_ip;
        reg [31:0] sum_a, sum_b, sum_c, sum_all;
        begin
            sum_a = 32'h00004500 + {16'd0, length} + 32'h00008011;
            sum_b = {16'd0, source_ip[31:16]} + {16'd0, source_ip[15:0]};
            sum_c = {16'd0, destination_ip[31:16]} + {16'd0, destination_ip[15:0]};
            sum_all = sum_a + sum_b + sum_c;
            sum_all = {16'd0, sum_all[15:0]} + {16'd0, sum_all[31:16]};
            sum_all = {16'd0, sum_all[15:0]} + {16'd0, sum_all[31:16]};
            ipv4_checksum = ~sum_all[15:0];
        end
    endfunction

    // Reflected Ethernet CRC32 consumes each byte LSB first. Cover only MAC
    // header, IP/UDP, payload and padding, excluding preamble, SFD and FCS.
    function [31:0] ethernet_crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer bit_index;
        begin
            c = previous ^ {24'd0, octet};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                c = c[0] ? ((c >> 1) ^ 32'hedb88320) : (c >> 1);
            ethernet_crc_byte = c;
        end
    endfunction

    // Independent synchronous RAM ports follow PDS ADS Language Support
    // Reference Manual 4.1.3.2. Do not reset RAM arrays. Ownership guarantees
    // initialized data and prevents same-bank read/write address collisions.
    reg [7:0] payload_bank0 [0:1463] /* synthesis syn_ramstyle = "block_ram" */;
    reg [7:0] payload_bank1 [0:1463] /* synthesis syn_ramstyle = "block_ram" */;
    reg [7:0] ram_read0, ram_read1;
    wire ram_read_enable = (tx_state == TX_BODY) && (body_index >= 11'd41)
                        && ({5'd0, body_index} < bank_length[tx_bank] + 16'd41);
    wire [10:0] ram_read_address = body_index - 11'd41;
    always @(posedge clk) begin
        if (payload_valid && payload_ready && !rx_bank)
            payload_bank0[rx_count] <= payload_data;
        if (reset_n && ram_read_enable && !tx_bank)
            ram_read0 <= payload_bank0[ram_read_address];
    end
    always @(posedge clk) begin
        if (payload_valid && payload_ready && rx_bank)
            payload_bank1[rx_count] <= payload_data;
        if (reset_n && ram_read_enable && tx_bank)
            ram_read1 <= payload_bank1[ram_read_address];
    end

    // Network order is explicit. The final UDP header byte (index 41) prefetches
    // RAM byte zero; reads then stay one byte ahead of the GMII byte register.
    // Padding extends only the MAC frame to 60 bytes, not IP/UDP lengths.
    reg [7:0] body_octet;
    always @(*) begin
        body_octet = 8'h00;
        case (body_index)
            0: body_octet = bank_dst_mac[tx_bank][47:40];
            1: body_octet = bank_dst_mac[tx_bank][39:32];
            2: body_octet = bank_dst_mac[tx_bank][31:24];
            3: body_octet = bank_dst_mac[tx_bank][23:16];
            4: body_octet = bank_dst_mac[tx_bank][15:8];
            5: body_octet = bank_dst_mac[tx_bank][7:0];
            6: body_octet = bank_src_mac[tx_bank][47:40];
            7: body_octet = bank_src_mac[tx_bank][39:32];
            8: body_octet = bank_src_mac[tx_bank][31:24];
            9: body_octet = bank_src_mac[tx_bank][23:16];
            10: body_octet = bank_src_mac[tx_bank][15:8];
            11: body_octet = bank_src_mac[tx_bank][7:0];
            12: body_octet = 8'h08;
            13: body_octet = 8'h00;
            14: body_octet = 8'h45;
            15: body_octet = 8'h00;
            16: body_octet = bank_ip_length[tx_bank][15:8];
            17: body_octet = bank_ip_length[tx_bank][7:0];
            18, 19: body_octet = 8'h00;
            20: body_octet = 8'h40;
            21: body_octet = 8'h00;
            22: body_octet = 8'h40;
            23: body_octet = 8'h11;
            24: body_octet = bank_ip_checksum[tx_bank][15:8];
            25: body_octet = bank_ip_checksum[tx_bank][7:0];
            26: body_octet = bank_src_ip[tx_bank][31:24];
            27: body_octet = bank_src_ip[tx_bank][23:16];
            28: body_octet = bank_src_ip[tx_bank][15:8];
            29: body_octet = bank_src_ip[tx_bank][7:0];
            30: body_octet = bank_dst_ip[tx_bank][31:24];
            31: body_octet = bank_dst_ip[tx_bank][23:16];
            32: body_octet = bank_dst_ip[tx_bank][15:8];
            33: body_octet = bank_dst_ip[tx_bank][7:0];
            34: body_octet = bank_src_port[tx_bank][15:8];
            35: body_octet = bank_src_port[tx_bank][7:0];
            36: body_octet = bank_dst_port[tx_bank][15:8];
            37: body_octet = bank_dst_port[tx_bank][7:0];
            38: body_octet = bank_udp_length[tx_bank][15:8];
            39: body_octet = bank_udp_length[tx_bank][7:0];
            40, 41: body_octet = 8'h00; // UDP checksum omitted for IPv4.
            default:
                if ({5'd0, body_index} < bank_length[tx_bank] + 16'd42)
                    body_octet = tx_bank ? ram_read1 : ram_read0;
        endcase
    end

    // Single queue-flag owner permits simultaneous RX/TX completion in different
    // banks. GMII never waits for input once a fully committed bank is launched.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bank_full <= 2'b00;
            rx_bank <= 1'b0;
            tx_bank <= 1'b0;
            rx_active <= 1'b0;
            rx_count <= 11'd0;
            rx_idle_count <= 0;
            tx_state <= TX_IDLE;
            preamble_index <= 3'd0;
            body_index <= 11'd0;
            fcs_index <= 2'd0;
            ifg_count <= 4'd0;
            crc_state <= 32'hffffffff;
            gmii_txd <= 8'd0;
            gmii_tx_en <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            for (bank_reset_index = 0; bank_reset_index < 2; bank_reset_index = bank_reset_index + 1) begin
                bank_src_mac[bank_reset_index] <= 48'd0;
                bank_dst_mac[bank_reset_index] <= 48'd0;
                bank_src_ip[bank_reset_index] <= 32'd0;
                bank_dst_ip[bank_reset_index] <= 32'd0;
                bank_src_port[bank_reset_index] <= 16'd0;
                bank_dst_port[bank_reset_index] <= 16'd0;
                bank_length[bank_reset_index] <= 16'd0;
                bank_ip_length[bank_reset_index] <= 16'd0;
                bank_udp_length[bank_reset_index] <= 16'd0;
                bank_body_length[bank_reset_index] <= 16'd0;
                bank_ip_checksum[bank_reset_index] <= 16'd0;
            end
        end else begin
            done <= 1'b0;
            error <= 1'b0;
            gmii_tx_en <= 1'b0;
            gmii_txd <= 8'd0;

            // Snapshot every dynamic field into the selected receive bank.
            if (datagram_start && datagram_ready) begin
                if (udp_payload_length == 0 || udp_payload_length > 16'd1464)
                    error <= 1'b1;
                else begin
                    rx_active <= 1'b1;
                    rx_count <= 11'd0;
                    rx_idle_count <= 0;
                    bank_src_mac[rx_bank] <= src_mac;
                    bank_dst_mac[rx_bank] <= dst_mac;
                    bank_src_ip[rx_bank] <= src_ip;
                    bank_dst_ip[rx_bank] <= dst_ip;
                    bank_src_port[rx_bank] <= src_port;
                    bank_dst_port[rx_bank] <= dst_port;
                    bank_length[rx_bank] <= udp_payload_length;
                    bank_ip_length[rx_bank] <= udp_payload_length + 16'd28;
                    bank_udp_length[rx_bank] <= udp_payload_length + 16'd8;
                    bank_body_length[rx_bank] <= (udp_payload_length < 16'd18)
                                                   ? 16'd60 : udp_payload_length + 16'd42;
                    bank_ip_checksum[rx_bank] <= ipv4_checksum(udp_payload_length + 16'd28, src_ip, dst_ip);
                end
            end
            // A transfer on the timeout deadline wins. Aborting advances neither
            // pointer nor full flag, so subsequent traffic preserves FIFO order.
            if (rx_active) begin
                if (payload_valid && payload_ready) begin
                    rx_idle_count <= 0;
                    if ({5'd0, rx_count} + 16'd1 == bank_length[rx_bank]) begin
                        bank_full[rx_bank] <= 1'b1;
                        rx_active <= 1'b0;
                        rx_bank <= ~rx_bank;
                    end else rx_count <= rx_count + 1'b1;
                end else if (rx_idle_count == TIMEOUT_LIMIT - 1) begin
                    rx_active <= 1'b0;
                    rx_idle_count <= 0;
                    error <= 1'b1;
                end else rx_idle_count <= rx_idle_count + 1'b1;
            end

            // Emit preamble immediately in IDLE, followed by header/payload/FCS
            // on every clock. crc_state excludes all preamble and FCS octets.
            case (tx_state)
                TX_IDLE: if (bank_full[tx_bank]) begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd <= 8'h55;
                    preamble_index <= 3'd1;
                    body_index <= 11'd0;
                    crc_state <= 32'hffffffff;
                    tx_state <= TX_PREAMBLE;
                end
                TX_PREAMBLE: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd <= (preamble_index == 3'd7) ? 8'hd5 : 8'h55;
                    if (preamble_index == 3'd7) tx_state <= TX_BODY;
                    else preamble_index <= preamble_index + 1'b1;
                end
                TX_BODY: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd <= body_octet;
                    crc_state <= ethernet_crc_byte(crc_state, body_octet);
                    if ({5'd0, body_index} + 16'd1 == bank_body_length[tx_bank]) begin
                        fcs_index <= 2'd0;
                        tx_state <= TX_FCS;
                    end else body_index <= body_index + 1'b1;
                end
                TX_FCS: begin
                    gmii_tx_en <= 1'b1;
                    case (fcs_index)
                        0: gmii_txd <= ~crc_state[7:0];
                        1: gmii_txd <= ~crc_state[15:8];
                        2: gmii_txd <= ~crc_state[23:16];
                        3: gmii_txd <= ~crc_state[31:24];
                    endcase
                    if (fcs_index == 2'd3) begin
                        done <= 1'b1;
                        bank_full[tx_bank] <= 1'b0;
                        tx_bank <= ~tx_bank;
                        ifg_count <= 4'd0;
                        tx_state <= TX_IFG;
                    end else fcs_index <= fcs_index + 1'b1;
                end
                // Exactly twelve low-enable clocks; receiving continues here.
                TX_IFG: begin
                    if (ifg_count == 4'd11) tx_state <= TX_IDLE;
                    else ifg_count <= ifg_count + 1'b1;
                end
                default: tx_state <= TX_IDLE;
            endcase
        end
    end
endmodule
