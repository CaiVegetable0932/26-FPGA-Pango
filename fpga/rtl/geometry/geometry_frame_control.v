// Purpose: stage geometry parameters and accepted MCU angle events, then make
// each set visible only at a processing-frame boundary. All ports are in clk;
// an independent MCU UART must be decoded and safely crossed before this port.
// This interface reserves posture metadata but does NOT treat its uncalibrated
// axis/zero or UART acceptance time as an exposure-synchronous rotation.
module geometry_frame_control (
    input wire clk, rst_n, frame_start,
    // Packed S(32,26) a00,a01,a02,a10,a11,a12,k1,k2,p1,p2, followed by
    // S(32,16) fx,fy,cx,cy, from least to most significant 32-bit word.
    input wire config_valid, input wire [447:0] config_words,
    input wire [31:0] config_version,
    output reg config_accepted, config_rejected,
    output reg active_config_valid, output reg [447:0] active_words,
    output reg [31:0] active_version,
    // V1 SUBMIT_ENVIRONMENT has already passed framing, CRC, session and
    // event-order checks in mcu_protocol; angle validity is bit1.
    input wire env_valid, input wire [1:0] env_measurement_valid,
    input wire signed [31:0] env_angle_mdeg,
    input wire [63:0] env_epoch, env_board_time_us,
    input wire [31:0] env_session_id, env_event_seq,
    // Current accepted MCU context, not merely the last environment event.
    input wire mcu_context_valid, input wire [63:0] mcu_epoch,
    input wire [31:0] mcu_session_id,
    output reg active_angle_valid,
    output reg signed [31:0] active_angle_mdeg,
    output reg [63:0] active_angle_epoch, active_angle_board_time_us,
    output reg [31:0] active_angle_session_id, active_angle_event_seq
);
    reg pending_config_valid;
    reg [447:0] pending_words;
    reg [31:0] pending_version;
    reg pending_angle_event, pending_angle_valid;
    reg signed [31:0] pending_angle_mdeg;
    reg [63:0] pending_angle_epoch, pending_angle_board_time_us;
    reg [31:0] pending_angle_session_id, pending_angle_event_seq;
    wire pending_context_ok = mcu_context_valid &&
        pending_angle_epoch == mcu_epoch && pending_angle_session_id == mcu_session_id;
    wire active_context_ok = mcu_context_valid &&
        active_angle_epoch == mcu_epoch && active_angle_session_id == mcu_session_id;

    // Purpose: reject nonphysical focal lengths and unsafe coefficient
    // magnitudes before a frame can use them. More precise calibration-domain
    // and overflow checks remain mandatory in the eventual UART command path.
    function magnitude_ok;
        input signed [31:0] value;
        input signed [31:0] limit;
        begin magnitude_ok = value >= -limit && value <= limit; end
    endfunction
    wire config_ok =
        $signed(config_words[351:320]) > 0 &&
        $signed(config_words[383:352]) > 0 &&
        $signed(config_words[351:320]) <= 32'sd268435456 &&
        $signed(config_words[383:352]) <= 32'sd268435456 &&
        magnitude_ok($signed(config_words[415:384]),32'sd268435456) &&
        magnitude_ok($signed(config_words[447:416]),32'sd268435456) &&
        magnitude_ok($signed(config_words[95:64]),32'sd268435456) &&
        magnitude_ok($signed(config_words[191:160]),32'sd268435456) &&
        magnitude_ok($signed(config_words[223:192]),32'sd67108864) &&
        magnitude_ok($signed(config_words[255:224]),32'sd67108864) &&
        magnitude_ok($signed(config_words[287:256]),32'sd67108864) &&
        magnitude_ok($signed(config_words[319:288]),32'sd67108864);

    // Purpose: a valid load replaces only the shadow set. A simultaneous
    // frame_start commits the PREVIOUS shadow set, never a half-updated one.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            config_accepted<=0;config_rejected<=0;pending_config_valid<=0;
            pending_words<=0;pending_version<=0;active_config_valid<=0;
            active_words<=0;active_version<=0;
            pending_angle_event<=0;pending_angle_valid<=0;pending_angle_mdeg<=0;
            pending_angle_epoch<=0;pending_angle_board_time_us<=0;
            pending_angle_session_id<=0;pending_angle_event_seq<=0;
            active_angle_valid<=0;active_angle_mdeg<=0;
            active_angle_epoch<=0;active_angle_board_time_us<=0;
            active_angle_session_id<=0;active_angle_event_seq<=0;
        end else begin
            config_accepted<=0;config_rejected<=0;
            if (frame_start) begin
                if (pending_config_valid) begin
                    active_words<=pending_words;active_version<=pending_version;
                    active_config_valid<=1;pending_config_valid<=0;
                end
                if (pending_angle_event && pending_context_ok) begin
                    active_angle_valid<=pending_angle_valid;
                    active_angle_mdeg<=pending_angle_mdeg;
                    active_angle_epoch<=pending_angle_epoch;
                    active_angle_board_time_us<=pending_angle_board_time_us;
                    active_angle_session_id<=pending_angle_session_id;
                    active_angle_event_seq<=pending_angle_event_seq;
                    pending_angle_event<=0;
                end
            end
            // Purpose: a new epoch/session invalidates stale posture even if
            // no replacement environment event has arrived yet.
            if (!active_context_ok && !(frame_start && pending_angle_event && pending_context_ok))
                active_angle_valid<=0;
            if (pending_angle_event && !pending_context_ok) pending_angle_event<=0;
            if (config_valid) begin
                if (config_ok) begin
                    pending_words<=config_words;pending_version<=config_version;
                    pending_config_valid<=1;config_accepted<=1;
                end else config_rejected<=1;
            end
            if (env_valid && mcu_context_valid && env_epoch==mcu_epoch &&
                env_session_id==mcu_session_id) begin
                pending_angle_event<=1;
                pending_angle_valid<=env_measurement_valid[1];
                pending_angle_mdeg<=env_angle_mdeg;
                pending_angle_epoch<=env_epoch;
                pending_angle_board_time_us<=env_board_time_us;
                pending_angle_session_id<=env_session_id;
                pending_angle_event_seq<=env_event_seq;
            end
        end
    end
endmodule
