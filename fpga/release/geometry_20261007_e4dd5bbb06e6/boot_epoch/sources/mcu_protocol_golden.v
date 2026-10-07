// Purpose: MCU observation endpoint with an opt-in PC geometry extension;
// no motor commands or video-stream startup control. All sidebands belong to
// clk. Geometry is disabled in legacy tops. The integrator supplies a fresh
// nonzero epoch after every reset/reconfiguration; leave epoch_valid low until
// that guarantee is available. Constant/reused epochs cannot isolate reboots.
module mcu_protocol_golden #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 115200,
    parameter integer RX_TIMEOUT_MS = 20,
    parameter integer BOARD_DIAGNOSTICS = 0,
    parameter integer VIDEO_DIAGNOSTICS = 0,
    parameter integer CHAIN_DIAGNOSTICS = 0,
    parameter integer GEOMETRY_CONTROL = 0,
    // Purpose: separately advertise frame-atomic display control; legacy tops
    // retain their exact capability word and reject opcode 0x35 by default.
    parameter integer DISPLAY_CONTROL = 0
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
    output wire session_active, output wire [31:0] current_session_id,
    // Purpose: optional same-clock PC geometry extension. Admission keeps the
    // existing CRC/epoch/session/queue rules; unsupported legacy tops stay off.
    output wire geometry_command_valid,output wire [7:0] geometry_command,
    output wire [255:0] geometry_payload,
    input wire [7:0] geometry_code,input wire [95:0] geometry_reply,
    output reg env_valid,
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
    assign current_session_id=active_session;

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
    // Purpose: frame lengths settle before payload/CRC. Parallel registered
    // exact matches remove the length bus from reply mux and admission paths.
    // Bit order: 0,12,16,20,24,32 bytes. Error frames bypass these predicates.
    reg [5:0] request_length_equal /* synthesis syn_preserve = 1 */;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)request_length_equal<=0;
        else request_length_equal<={request_length==16'd32,request_length==16'd24,
            request_length==16'd20,request_length==16'd16,
            request_length==16'd12,request_length==16'd0};
    // Purpose: session payload precedes both CRC bytes, just like the epoch.
    // Precompute comparisons before frame_done to remove the session bus from
    // parameter write CEs. OPEN/epoch changes flush or precede the next frame;
    // parser errors bypass session checks. No request or response latency added.
    reg request_session_equal,request_session_nonzero,request_session_less
        /* synthesis syn_preserve = 1 */;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)begin
            request_session_equal<=0;request_session_nonzero<=0;request_session_less<=0;
        end else begin
            request_session_equal<=request_payload[95:64]==active_session;
            request_session_nonzero<=request_payload[95:64]!=0;
            request_session_less<=request_payload[95:64]<active_session;
        end
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
    // Purpose: synchronous RAM reply queue. The registered head retains the
    // original same-cycle visibility, while synchronous lookahead eliminates
    // the wide eight-way register mux and the old LUT-RAM-to-TX bypass.
    wire [279:0] reply_front;
    wire [3:0] queue_count;
    // Purpose: reserve a response before side effects, then register its entire
    // snapshot before writing the reply RAM queue. The pending slot counts toward the
    // fixed eight-slot capacity; epoch changes flush it with the queue.
    reg pending_reply;
    reg [255:0] pending_payload /* synthesis syn_preserve = 1 */;
    reg [15:0] pending_seq;
    reg [7:0] pending_command;
    // Purpose: capture the geometry reply independently of the common reply
    // mux, on the SAME acceptance edge. Assemble it at FIFO write next cycle;
    // this cuts the config readback-to-prefix-mux path without a stale snapshot
    // or extra queue slot. Epoch changes invalidate both pieces together.
    reg [95:0] pending_geometry_data /* synthesis syn_preserve=1 */;
    reg pending_geometry;
    wire response_geometry=(GEOMETRY_CONTROL && request_command>=8'h30 && request_command<=8'h34) ||
        (DISPLAY_CONTROL && request_command==8'h35);
    wire [255:0] queued_payload=pending_geometry ?
        {pending_geometry_data,pending_payload[159:0]} : pending_payload;
    wire tx_ready;
    wire pop = (queue_count != 0) && tx_ready && !epoch_change;
    wire space_available = (queue_count + {3'b0,pending_reply} < 8) || pop;
    wire push = frame_done && reply_allowed && space_available && !epoch_change;
    reg [7:0] response_code, admission_code;
    reg accept_session, accept_event, admit_geometry;
    reg [255:0] response_payload;
    // Purpose: read-only snapshot replies all share this direct validity
    // predicate. Do not encode an error number and decode it back to OK before
    // selecting 96 data bits. These checks exactly match the 12-byte commands;
    // optional diagnostic capability checks remain local to each reply kind.
    wire snapshot_ok=(parse_error==0) && request_length_equal[1] && epoch_ready &&
        (&request_epoch_equal) && request_session_nonzero && request_session_equal;
    // Purpose: directly decode the exclusive reply kinds. CAPS validity is
    // independent of epoch/session; enabled geometry reserves its tail even on
    // errors. Invalid/disabled snapshot queries use the ordinary status tail.
    wire reply_caps=(request_command==CAPS) && (parse_error==0) && request_length_equal[0];
    wire reply_counters=(request_command==COUNTERS) && snapshot_ok;
    wire reply_board=(request_command==DIAGNOSTICS) && BOARD_DIAGNOSTICS && snapshot_ok;
    wire reply_video=(request_command==VIDEO_SNAPSHOT) && VIDEO_DIAGNOSTICS && snapshot_ok;
    wire reply_dvp_geometry=(request_command==DVP_GEOMETRY) && CHAIN_DIAGNOSTICS && snapshot_ok;
    wire reply_dvp_progress=(request_command==DVP_PROGRESS) && CHAIN_DIAGNOSTICS && snapshot_ok;
    wire reply_pipeline=(request_command==PIPELINE) && CHAIN_DIAGNOSTICS && snapshot_ok;
    // Purpose: fallback depends directly on command class and validity, avoiding
    // a serial priority encoder and avoiding a response_code-to-OK decode.
    wire reply_snapshot_command=(request_command==COUNTERS) ||
        ((request_command==DIAGNOSTICS) && BOARD_DIAGNOSTICS) ||
        ((request_command==VIDEO_SNAPSHOT) && VIDEO_DIAGNOSTICS) ||
        (((request_command==DVP_GEOMETRY) || (request_command==DVP_PROGRESS) ||
          (request_command==PIPELINE)) && CHAIN_DIAGNOSTICS);
    wire reply_default=!(reply_caps || (reply_snapshot_command && snapshot_ok) || response_geometry);
    wire [31:0] reply_good_next=rx_good_count+32'd1;
    wire [31:0] reply_error_next=rx_error_count+32'd1;
    localparam [31:0] REPLY_CAPABILITIES=32'h0000000f |
        (BOARD_DIAGNOSTICS ? 32'h10 : 32'h0) | (VIDEO_DIAGNOSTICS ? 32'h20 : 32'h0) |
        (CHAIN_DIAGNOSTICS ? 32'h40 : 32'h0) | (GEOMETRY_CONTROL ? 32'h80 : 32'h0) |
        (DISPLAY_CONTROL ? 32'h100 : 32'h0);
    localparam [31:0] REPLY_BAUD=BAUD;
    wire [95:0] reply_caps_data={REPLY_BAUD,REPLY_CAPABILITIES,16'd32,16'd1024};
    wire [95:0] reply_counters_data={tx_overflow_count,rx_error_count,reply_good_next};
    wire [95:0] reply_default_data={
        ((admission_code>=2) ? reply_error_next : rx_error_count),
        ((parse_error==0) ? reply_good_next : rx_good_count),status_flags};
    wire [95:0] reply_extension;
    genvar reply_lane;
    generate for(reply_lane=0;reply_lane<3;reply_lane=reply_lane+1) begin: g_reply_lane
        // Purpose: independently OR the masked sources in each 32-bit lane.
        // Geometry contributes zero here; its existing separate capture still
        // joins at FIFO write. No pipeline stage, admission CE or reset changes.
        assign reply_extension[reply_lane*32+:32]=
            ({32{reply_default}} & reply_default_data[reply_lane*32+:32]) |
            ({32{reply_caps}} & reply_caps_data[reply_lane*32+:32]) |
            ({32{reply_counters}} & reply_counters_data[reply_lane*32+:32]) |
            ({32{reply_board}} & board_diagnostics[reply_lane*32+:32]) |
            ({32{reply_video}} & video_diagnostics[reply_lane*32+:32]) |
            ({32{reply_dvp_geometry}} & chain_diagnostics[reply_lane*32+:32]) |
            ({32{reply_dvp_progress}} & chain_diagnostics[96+reply_lane*32+:32]) |
            ({32{reply_pipeline}} & chain_diagnostics[192+reply_lane*32+:32]);
    end endgenerate
    // Purpose: declare extension wiring after parser/admission signals to
    // avoid implicit nets in the installed Verilog/ModelSim tool versions.
    assign geometry_command=request_command;
    assign geometry_payload=request_payload;
    // Admission covers transport/session/queue checks only. The config bank
    // already gates its own mutations with code==OK; do not route its code
    // back through the MCU decoder to its write enable a second time.
    assign geometry_command_valid=push && admit_geometry;
    // The front caches stored words; it is not an extra response slot. The
    // existing pending reservation and eight-slot admission remain unchanged.
    mcu_reply_queue_ram u_reply_queue (
        .clk(clk),.rst_n(rst_n),.flush(epoch_change),.write(pending_reply),
        .write_data({pending_command,pending_seq,queued_payload}),.pop(pop),
        .count(queue_count),.front(reply_front));
    mcu_frame_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx (
        .clk(clk),.rst_n(rst_n),.flush(epoch_change),.valid(queue_count != 0),
        .ready(tx_ready),.command(reply_front[279:272]),
        .sequence_id(reply_front[271:256]),.payload(reply_front[255:0]),
        .serial_tx(uart_tx));

    // Decode only CRC/version/length-validated frames. Session IDs increase
    // without wrap within an epoch. Event IDs increase within a session;
    // identical last-event retries are acknowledged without another pulse.
    always @* begin
        // Purpose: keep transport/session decoding independent of the late
        // geometry-layer code. Geometry replaces its entire upper snapshot,
        // so that code must not traverse unrelated status/counter reply muxes.
        admission_code = parse_error; accept_session = 0; accept_event = 0; admit_geometry=0;
        if (parse_error == 0) begin
            admission_code = OK;
            case (request_command)
                CAPS: if (!request_length_equal[0]) admission_code = BAD_LENGTH;
                OPEN, STATUS, COUNTERS, DIAGNOSTICS, VIDEO_SNAPSHOT,
                DVP_GEOMETRY, DVP_PROGRESS, PIPELINE, ENVIRONMENT,
                8'h30,8'h31,8'h32,8'h33,8'h34,8'h35: begin
                    if ((request_command == DIAGNOSTICS && !BOARD_DIAGNOSTICS) ||
                        (request_command == VIDEO_SNAPSHOT && !VIDEO_DIAGNOSTICS) ||
                        ((request_command==DVP_GEOMETRY || request_command==DVP_PROGRESS ||
                          request_command==PIPELINE) && !CHAIN_DIAGNOSTICS) ||
                        (request_command>=8'h30 && request_command<=8'h34 && !GEOMETRY_CONTROL) ||
                        (request_command==8'h35 && !DISPLAY_CONTROL))
                        admission_code = UNSUPPORTED;
                    else if ((request_command == ENVIRONMENT && !request_length_equal[5]) ||
                        ((request_command==8'h30 || request_command==8'h31 || request_command==8'h35) && !request_length_equal[4]) ||
                        (request_command==8'h32 && !request_length_equal[2]) ||
                        (request_command==8'h34 && !request_length_equal[3]) ||
                        (request_command!=ENVIRONMENT && request_command!=8'h30 &&
                         request_command!=8'h31 && request_command!=8'h32 &&
                         request_command!=8'h34 && request_command!=8'h35 && !request_length_equal[1]))
                        admission_code = BAD_LENGTH;
                    else if (!epoch_ready) admission_code = NOT_READY;
                    else if (!(&request_epoch_equal)) admission_code = BAD_EPOCH;
                    else if (!request_session_nonzero) admission_code = BAD_SESSION;
                    else if (request_command == OPEN) begin
                        if (request_session_equal) admission_code = DUPLICATE;
                        else if (request_session_less) admission_code = BAD_SESSION;
                        else accept_session = 1;
                    end else if (!request_session_equal) admission_code = BAD_SESSION;
                    else if (request_command>=8'h30 && request_command<=8'h35) begin
                        admit_geometry=1;
                    end
                    else if (request_command == ENVIRONMENT) begin
                        if (request_payload[255:226] != 0) admission_code = BAD_FORMAT;
                        else if (request_payload[127:96] == 0 ||
                                 request_payload[127:96] < env_event_seq) admission_code = STALE_EVENT;
                        else if (request_payload[127:96] == env_event_seq) begin
                            if (&event_chunk_equal) admission_code = DUPLICATE;
                            else admission_code = ID_CONFLICT;
                        end else accept_event = 1;
                    end
                end
                default: admission_code = UNSUPPORTED;
            endcase
        end
        // Actual wire ACK/NACK, prefix and error counters retain the complete
        // code, including geometry failures. Only irrelevant upper fields use
        // admission_code; geometry overwrites those fields unconditionally.
        response_code=admit_geometry ? geometry_code : admission_code;

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
        // Purpose: mutually exclusive opcodes allow parallel masked data terms
        // instead of seven successive priority choices over the 96-bit tail.
        // Keep the same-edge snapshot of status/counters and pending registers.
        response_payload[255:160] = reply_extension;
    end

    // Purpose: snapshot buses run every cycle; pending_reply alone authorizes
    // consumption on the following edge. Thus the accepted snapshot is still
    // taken on push, while wide data flops need neither a late admission CE nor
    // reset routing. Reset/epoch flush clears the validity token, not the data.
    always @(posedge clk) begin
        pending_payload<=response_payload;pending_seq<=request_seq;
        pending_command<=(response_code<2)?8'h80:8'h81;
        pending_geometry<=response_geometry;pending_geometry_data<=geometry_reply;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pending_reply<=0;
        else if(epoch_change) pending_reply<=0;
        else pending_reply<=push;
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

// Purpose: private synchronous-RAM reply queue for mcu_protocol. Bundled here
// to preserve existing PDS source lists. Keep the eight-slot interface while replacing
// the wide register bank with synchronous block RAM. The head and lookahead
// duplicate stored slots; they do not add logical capacity or response delay.
module mcu_reply_queue_ram (
    input wire clk, input wire rst_n, input wire flush,
    input wire write, input wire [279:0] write_data, input wire pop,
    output reg [3:0] count, output reg [279:0] front
);
    reg [279:0] memory [0:7] /* synthesis syn_ramstyle="block_ram" */;
    reg [2:0] write_ptr, read_ptr;
    reg [279:0] ram_ahead, forwarded;
    reg forward_valid;
    // Purpose: fetch the successor of the head AFTER this edge. Explicit
    // write forwarding defines collision data independent of the RAM mode.
    wire [2:0] ahead_address=read_ptr+(pop ? 3'd2 : 3'd1);
    wire [279:0] next_front=forward_valid ? forwarded : ram_ahead;
    always @(posedge clk) begin
        if (write && rst_n && !flush) memory[write_ptr]<=write_data;
        ram_ahead<=memory[ahead_address];
        forward_valid<=write && rst_n && !flush && write_ptr==ahead_address;
        if (write && rst_n && !flush && write_ptr==ahead_address)
            forwarded<=write_data;
    end
    // Purpose: direct first-word forwarding preserves the original queue's
    // visibility on empty writes and one-word simultaneous pop/push. For a
    // deeper queue the synchronous lookahead was prepared on the prior edge.
    // No RAM/head reset is needed: count prevents stale/uninitialized reads.
    always @(posedge clk) begin
        if (rst_n && !flush) begin
            if (write && (count==0 || (pop && count==1))) front<=write_data;
            else if (pop && count>1) front<=next_front;
        end
    end
    // Purpose: the caller reserves capacity before write, and pops only when
    // count is nonzero. Reset/epoch flush invalidates every queued response.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin count<=0;write_ptr<=0;read_ptr<=0;end
        else if (flush) begin count<=0;write_ptr<=0;read_ptr<=0;end
        else begin
            if(write)write_ptr<=write_ptr+1'b1;
            if(pop)read_ptr<=read_ptr+1'b1;
            case ({write,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
        end
    end
endmodule
