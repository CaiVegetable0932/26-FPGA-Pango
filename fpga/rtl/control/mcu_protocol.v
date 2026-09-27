// Purpose: MCU-only binary endpoint; no motor commands and no video stream
// control. All sideband ports belong to clk. The integrator must supply a fresh
// nonzero epoch after every reset/reconfiguration; leave epoch_valid low until
// that guarantee is available. Constant/reused epochs cannot isolate reboots.
module mcu_protocol #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 115200,
    parameter integer RX_TIMEOUT_MS = 20,
    parameter integer BOARD_DIAGNOSTICS = 0,
    parameter integer VIDEO_DIAGNOSTICS = 0,
    parameter integer CHAIN_DIAGNOSTICS = 0
) (
    input wire clk, input wire rst_n,
    input wire uart_rx, output wire uart_tx,
    input wire [63:0] link_epoch, input wire link_epoch_valid,
    input wire [63:0] board_time_us, input wire [31:0] status_flags,
    // Optional read-only board snapshot; valid only when capability bit4 is set.
    input wire [95:0] board_diagnostics,
    // Purpose: optional same-clock first-failure snapshot, capability bit5.
    input wire [95:0] video_diagnostics,
    // Purpose: mem-clock snapshots for DVP geometry/progress and frame pipeline.
    input wire [287:0] chain_diagnostics,
    output wire session_active, output reg env_valid,
    output reg [31:0] env_session_id, output reg [31:0] env_event_seq,
    output reg [31:0] env_mcu_time_us, output reg [63:0] env_board_time_us,
    output reg [31:0] env_lux_milli, output reg signed [31:0] env_angle_mdeg,
    output reg [1:0] env_measurement_valid,
    output reg [31:0] rx_good_count, output reg [31:0] rx_error_count,
    output reg [31:0] tx_overflow_count
);
    localparam [7:0] OK=0, DUPLICATE=1, BAD_LENGTH=3, UNSUPPORTED=6,
        BAD_EPOCH=7, BAD_SESSION=8, STALE_EVENT=9, ID_CONFLICT=10,
        BAD_FORMAT=11, NOT_READY=13;
    localparam [7:0] CAPS=8'h01, OPEN=8'h02, STATUS=8'h03,
        COUNTERS=8'h04, DIAGNOSTICS=8'h05, VIDEO_SNAPSHOT=8'h06,
        DVP_GEOMETRY=8'h07, DVP_PROGRESS=8'h08, PIPELINE=8'h09, ENVIRONMENT=8'h10;
    reg [63:0] observed_epoch;
    reg observed_epoch_valid;
    wire epoch_change = (link_epoch != observed_epoch) ||
                        (link_epoch_valid != observed_epoch_valid);
    // Purpose: predecode the stable epoch's nonzero status. epoch_change flushes
    // all admission during an update, so no request uses the preceding value.
    reg epoch_nonzero /* synthesis syn_preserve = 1 */;
    wire epoch_ready = link_epoch_valid && epoch_nonzero;
    reg [31:0] active_session;
    reg [255:0] last_event_payload;
    assign session_active = (active_session != 0) && epoch_ready && !epoch_change;

    // Changes invalidate parser, queued replies, handshake, and measurement
    // validity together. The top must synchronize/stabilize these input buses.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin observed_epoch <= 0; observed_epoch_valid <= 0; epoch_nonzero <= 0; end
        else begin observed_epoch <= link_epoch; observed_epoch_valid <= link_epoch_valid; epoch_nonzero <= link_epoch != 0; end
    end

    wire [7:0] rx_byte, request_command, parse_error;
    wire [15:0] request_seq, request_length;
    wire [255:0] request_payload;
    wire byte_valid, framing_error, frame_done, reply_allowed;
    // Purpose: payload epoch is stable before the CRC bytes/frame_done. Compare
    // two registered halves so 64-bit equality is not cascaded with response
    // decoding, counter increments and inferred reply-memory bypass at 125 MHz.
    reg [1:0] request_epoch_equal /* synthesis syn_preserve = 1 */;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) request_epoch_equal <= 0;
        else begin
            request_epoch_equal[0] <= request_payload[31:0] == link_epoch[31:0];
            request_epoch_equal[1] <= request_payload[63:32] == link_epoch[63:32];
        end
    // Purpose: break the 256-bit duplicate-event comparison into eight parallel
    // registered 32-bit checks. The parser commits payload bytes BEFORE the two
    // CRC bytes and asserts frame_done afterwards, so these checks are current
    // when the request is decoded (even with a byte every clock). No extra
    // request latency or change to duplicate/id-conflict semantics is introduced.
    // Preserve the registers so synthesis cannot rebuild a single long carry
    // comparator on the response-code/counter/queue write path at 125 MHz.
    reg [7:0] event_chunk_equal /* synthesis syn_preserve = 1 */;
    integer event_chunk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) event_chunk_equal <= 0;
        else if (epoch_change) event_chunk_equal <= 0;
        else for (event_chunk=0; event_chunk<8; event_chunk=event_chunk+1)
            event_chunk_equal[event_chunk] <=
                request_payload[event_chunk*32 +: 32] == last_event_payload[event_chunk*32 +: 32];
    end
    mcu_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx (
        .clk(clk),.rst_n(rst_n),.flush(epoch_change),.serial_rx(uart_rx),
        .data(rx_byte),.valid(byte_valid),.framing_error(framing_error));
    mcu_frame_rx #(.CLK_HZ(CLK_HZ),.RX_TIMEOUT_MS(RX_TIMEOUT_MS)) u_parser (
        .clk(clk),.rst_n(rst_n),.flush(epoch_change),.byte_data(rx_byte),
        .byte_valid(byte_valid),.framing_error(framing_error),.done(frame_done),
        .reply_allowed(reply_allowed),.error_code(parse_error),.command(request_command),
        .sequence_id(request_seq),.length(request_length),.payload(request_payload));

    // Eight response slots bound storage. Acceptance reserves a response slot
    // before changing state; overload drops a request without side effects.
    reg [255:0] reply_payload_fifo [0:7];
    reg [15:0] reply_seq_fifo [0:7];
    reg [7:0] reply_command_fifo [0:7];
    reg [2:0] write_ptr, read_ptr;
    reg [3:0] queue_count;
    // Purpose: reserve a response before side effects, then register its entire
    // snapshot before writing the reply RAM. The pending slot counts toward the
    // fixed eight-slot capacity; epoch changes flush it with the queue.
    reg pending_reply;
    reg [255:0] pending_payload /* synthesis syn_preserve = 1 */;
    reg [15:0] pending_seq;
    reg [7:0] pending_command;
    wire tx_ready;
    wire pop = (queue_count != 0) && tx_ready && !epoch_change;
    wire space_available = (queue_count + {3'b0,pending_reply} < 8) || pop;
    wire push = frame_done && reply_allowed && space_available && !epoch_change;
    reg [7:0] response_code;
    reg accept_session, accept_event;
    reg [255:0] response_payload;
    mcu_frame_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx (
        .clk(clk),.rst_n(rst_n),.flush(epoch_change),.valid(queue_count != 0),
        .ready(tx_ready),.command(reply_command_fifo[read_ptr]),
        .sequence_id(reply_seq_fifo[read_ptr]),.payload(reply_payload_fifo[read_ptr]),
        .serial_tx(uart_tx));

    // Decode only CRC/version/length-validated frames. Session IDs increase
    // without wrap within an epoch. Event IDs increase within a session;
    // identical last-event retries are acknowledged without another pulse.
    always @* begin
        response_code = parse_error; accept_session = 0; accept_event = 0;
        if (parse_error == 0) begin
            response_code = OK;
            case (request_command)
                CAPS: if (request_length != 0) response_code = BAD_LENGTH;
                OPEN, STATUS, COUNTERS, DIAGNOSTICS, VIDEO_SNAPSHOT,
                DVP_GEOMETRY, DVP_PROGRESS, PIPELINE, ENVIRONMENT: begin
                    if ((request_command == DIAGNOSTICS && !BOARD_DIAGNOSTICS) ||
                        (request_command == VIDEO_SNAPSHOT && !VIDEO_DIAGNOSTICS) ||
                        ((request_command==DVP_GEOMETRY || request_command==DVP_PROGRESS ||
                          request_command==PIPELINE) && !CHAIN_DIAGNOSTICS))
                        response_code = UNSUPPORTED;
                    else if ((request_command == ENVIRONMENT && request_length != 32) ||
                        (request_command != ENVIRONMENT && request_length != 12))
                        response_code = BAD_LENGTH;
                    else if (!epoch_ready) response_code = NOT_READY;
                    else if (!(&request_epoch_equal)) response_code = BAD_EPOCH;
                    else if (request_payload[95:64] == 0) response_code = BAD_SESSION;
                    else if (request_command == OPEN) begin
                        if (request_payload[95:64] == active_session) response_code = DUPLICATE;
                        else if (request_payload[95:64] < active_session) response_code = BAD_SESSION;
                        else accept_session = 1;
                    end else if (request_payload[95:64] != active_session) response_code = BAD_SESSION;
                    else if (request_command == ENVIRONMENT) begin
                        if (request_payload[255:226] != 0) response_code = BAD_FORMAT;
                        else if (request_payload[127:96] == 0 ||
                                 request_payload[127:96] < env_event_seq) response_code = STALE_EVENT;
                        else if (request_payload[127:96] == env_event_seq) begin
                            if (&event_chunk_equal) response_code = DUPLICATE;
                            else response_code = ID_CONFLICT;
                        end else accept_event = 1;
                    end
                end
                default: response_code = UNSUPPORTED;
            endcase
        end

        // Common 20-byte response prefix followed by 12 command-specific bytes.
        // Snapshot reflects successful mutation and this request's counters.
        response_payload = 0;
        response_payload[7:0] = response_code;
        response_payload[15:8] = request_command;
        response_payload[16] = session_active || accept_session;
        response_payload[17] = epoch_ready;
        response_payload[25:24] = accept_session ? 2'b00 :
                                  (accept_event ? request_payload[225:224] : env_measurement_valid);
        response_payload[95:32] = epoch_ready ? link_epoch : 64'd0;
        response_payload[127:96] = accept_session ? request_payload[95:64] : active_session;
        response_payload[159:128] = accept_session ? 32'd0 :
                                    (accept_event ? request_payload[127:96] : env_event_seq);
        response_payload[191:160] = status_flags;
        response_payload[223:192] = rx_good_count + ((parse_error == 0) ? 32'd1 : 32'd0);
        response_payload[255:224] = rx_error_count + ((response_code >= 2) ? 32'd1 : 32'd0);
        if (request_command == CAPS && response_code == OK) begin
            response_payload[175:160] = 16'd1024;
            response_payload[191:176] = 16'd32;
            response_payload[223:192] = 32'h0000000f |
                (BOARD_DIAGNOSTICS ? 32'h10 : 32'h0) | (VIDEO_DIAGNOSTICS ? 32'h20 : 32'h0) |
                (CHAIN_DIAGNOSTICS ? 32'h40 : 32'h0);
            response_payload[255:224] = BAUD;
        end else if (request_command == COUNTERS && response_code == OK) begin
            response_payload[191:160] = rx_good_count+1'b1;
            response_payload[223:192] = rx_error_count;
            response_payload[255:224] = tx_overflow_count;
        end else if (request_command == DIAGNOSTICS && response_code == OK) begin
            // Purpose: correlated, session-checked snapshot in the existing
            // 12-byte extension area; never writes a PHY or changes streaming.
            response_payload[255:160] = board_diagnostics;
        end else if (request_command == VIDEO_SNAPSHOT && response_code == OK) begin
            // Purpose: same epoch/session validation as PHY telemetry; snapshot
            // is read-only and does not reset fault latches or restart capture.
            response_payload[255:160] = video_diagnostics;
        end else if (request_command == DVP_GEOMETRY && response_code == OK) begin
            // Purpose: each command captures its own coherent 96-bit page;
            // separate replies are NOT an atomic shared frame identity.
            response_payload[255:160] = chain_diagnostics[95:0];
        end else if (request_command == DVP_PROGRESS && response_code == OK) begin
            response_payload[255:160] = chain_diagnostics[191:96];
        end else if (request_command == PIPELINE && response_code == OK) begin
            response_payload[255:160] = chain_diagnostics[287:192];
        end
    end

    // Queue memory needs no reset: pointers/count prevent reading stale data.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pending_reply<=0;pending_payload<=0;pending_seq<=0;pending_command<=0;end
        else if(epoch_change) pending_reply<=0;
        else begin
            pending_reply<=push;
            if(push) begin
                pending_payload<=response_payload;pending_seq<=request_seq;
                pending_command<=(response_code<2)?8'h80:8'h81;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin write_ptr <= 0; read_ptr <= 0; queue_count <= 0; end
        else if (epoch_change) begin write_ptr <= 0; read_ptr <= 0; queue_count <= 0; end
        else begin
            if (pending_reply) begin
                reply_payload_fifo[write_ptr] <= pending_payload;
                reply_seq_fifo[write_ptr] <= pending_seq;
                reply_command_fifo[write_ptr] <= pending_command;
                write_ptr <= write_ptr+1'b1;
            end
            if (pop) read_ptr <= read_ptr+1'b1;
            case ({pending_reply,pop})
                2'b10: queue_count <= queue_count+1'b1;
                2'b01: queue_count <= queue_count-1'b1;
                default: begin end
            endcase
        end
    end

    // Latched environment outputs update atomically only after all checks and
    // response reservation. MCU time is never copied into board time.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_session <= 0; env_valid <= 0; env_session_id <= 0; env_event_seq <= 0;
            env_mcu_time_us <= 0; env_board_time_us <= 0; env_lux_milli <= 0;
            env_angle_mdeg <= 0; env_measurement_valid <= 0; last_event_payload <= 0;
        end else begin
            env_valid <= 0;
            if (epoch_change || (push && accept_session)) begin
                active_session <= epoch_change ? 32'd0 : request_payload[95:64];
                env_session_id <= 0; env_event_seq <= 0; env_mcu_time_us <= 0;
                env_board_time_us <= 0; env_lux_milli <= 0; env_angle_mdeg <= 0;
                env_measurement_valid <= 0; last_event_payload <= 0;
            end else if (push && accept_event) begin
                env_valid <= 1; env_session_id <= active_session;
                env_event_seq <= request_payload[127:96];
                env_mcu_time_us <= request_payload[159:128]; env_board_time_us <= board_time_us;
                env_lux_milli <= request_payload[191:160]; env_angle_mdeg <= request_payload[223:192];
                env_measurement_valid <= request_payload[225:224]; last_event_payload <= request_payload;
            end
        end
    end

    // Counters wrap modulo 2^32 and survive epoch changes, but reset on rst_n.
    // A transport-valid request may also increment errors if its command fails.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_good_count <= 0; rx_error_count <= 0; tx_overflow_count <= 0; end
        else if (frame_done && !epoch_change) begin
            if (parse_error == 0) rx_good_count <= rx_good_count+1'b1;
            if (response_code >= 2 || (reply_allowed && !space_available))
                rx_error_count <= rx_error_count+1'b1;
            if (reply_allowed && !space_available) tx_overflow_count <= tx_overflow_count+1'b1;
        end
    end
endmodule
