// Purpose: parse the shared 55 AA / little-endian UART envelope without a
// 1024-byte buffer. Store only 32 bytes; drain legal larger frames before NACK.
// A declared length >1024 or UART framing error quarantines input until an idle
// timeout, preventing embedded payload bytes from executing as a nested frame.
module mcu_frame_rx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer RX_TIMEOUT_MS = 20
) (
    input wire clk, input wire rst_n, input wire flush,
    input wire [7:0] byte_data, input wire byte_valid, input wire framing_error,
    output reg done, output reg reply_allowed,
    output reg [7:0] error_code, output reg [7:0] command,
    output reg [15:0] sequence_id, output reg [15:0] length,
    output reg [255:0] payload
);
    localparam integer TIMEOUT_TICKS = (CLK_HZ/1000)*RX_TIMEOUT_MS;
    localparam [3:0] SYNC0=0, SYNC1=1, VERSION=2, COMMAND=3, SEQ0=4,
        SEQ1=5, LEN0=6, LEN1=7, PAYLOAD=8, CRC0=9, CRC1=10, DISCARD=11;
    localparam [7:0] BAD_CRC=2, BAD_LENGTH=3, TIMEOUT=4, BAD_VERSION=5, UART_ERROR=12;
    reg [3:0] state;
    reg [7:0] version, crc_low;
    reg [15:0] crc, received;
    reg [31:0] idle_ticks;
    reg header_known;

    // CCITT-FALSE: polynomial 1021, initial FFFF, MSB-first, no final xor.
    function [15:0] crc_byte;
        input [15:0] prior;
        input [7:0] value;
        integer i;
        reg [15:0] c;
        begin
            c = prior ^ {value,8'h00};
            for (i=0; i<8; i=i+1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    // Only complete envelopes, or explicit parse errors, produce a done pulse.
    // Unknown/truncated headers are counted but cannot yield a correlated NACK.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SYNC0; done <= 0; reply_allowed <= 0; error_code <= 0;
            command <= 0; sequence_id <= 0; length <= 0; payload <= 0;
            version <= 0; crc_low <= 0; crc <= 16'hffff; received <= 0;
            idle_ticks <= 0; header_known <= 0;
        end else begin
            done <= 0;
            if (flush) begin state <= SYNC0; idle_ticks <= 0; header_known <= 0; end
            else if (framing_error) begin
                if (state != DISCARD) begin
                    done <= 1; error_code <= UART_ERROR; reply_allowed <= header_known;
                end
                state <= DISCARD; idle_ticks <= 0;
            end else if (byte_valid) begin
                idle_ticks <= 0;
                case (state)
                    SYNC0: if (byte_data == 8'h55) begin
                        state <= SYNC1; header_known <= 0;
                        command <= 0; sequence_id <= 0; length <= 0; payload <= 0;
                    end
                    SYNC1: if (byte_data == 8'haa) begin state <= VERSION; crc <= 16'hffff; end
                        else if (byte_data != 8'h55) state <= SYNC0;
                    VERSION: begin
                        version <= byte_data; crc <= crc_byte(crc,byte_data); state <= COMMAND;
                    end
                    COMMAND: begin
                        command <= byte_data; crc <= crc_byte(crc,byte_data); state <= SEQ0;
                    end
                    SEQ0: begin
                        sequence_id[7:0] <= byte_data; crc <= crc_byte(crc,byte_data); state <= SEQ1;
                    end
                    SEQ1: begin
                        sequence_id[15:8] <= byte_data; crc <= crc_byte(crc,byte_data);
                        header_known <= 1; state <= LEN0;
                    end
                    LEN0: begin
                        length[7:0] <= byte_data; crc <= crc_byte(crc,byte_data); state <= LEN1;
                    end
                    LEN1: begin
                        length[15:8] <= byte_data; crc <= crc_byte(crc,byte_data); received <= 0;
                        if ({byte_data,length[7:0]} > 16'd1024) begin
                            done <= 1; error_code <= BAD_LENGTH; reply_allowed <= 1; state <= DISCARD;
                        end else if ({byte_data,length[7:0]} == 0) state <= CRC0;
                        else state <= PAYLOAD;
                    end
                    PAYLOAD: begin
                        if (received < 32) payload[received[4:0]*8 +: 8] <= byte_data;
                        crc <= crc_byte(crc,byte_data); received <= received+1'b1;
                        if (received == length-1'b1) state <= CRC0;
                    end
                    CRC0: begin crc_low <= byte_data; state <= CRC1; end
                    CRC1: begin
                        done <= 1; reply_allowed <= 1; state <= SYNC0; header_known <= 0;
                        if ({byte_data,crc_low} != crc) error_code <= BAD_CRC;
                        else if (version != 1) error_code <= BAD_VERSION;
                        else if (length > 32) error_code <= BAD_LENGTH;
                        else error_code <= 0;
                    end
                    DISCARD: begin end // Consume noise until the inter-byte idle deadline.
                    default: state <= SYNC0;
                endcase
            end else if (state != SYNC0) begin
                if (idle_ticks >= TIMEOUT_TICKS-1) begin
                    if (state != DISCARD) begin
                        done <= 1; error_code <= TIMEOUT; reply_allowed <= header_known;
                    end
                    state <= SYNC0; idle_ticks <= 0; header_known <= 0;
                end else idle_ticks <= idle_ticks+1'b1;
            end else idle_ticks <= 0;
        end
    end
endmodule
