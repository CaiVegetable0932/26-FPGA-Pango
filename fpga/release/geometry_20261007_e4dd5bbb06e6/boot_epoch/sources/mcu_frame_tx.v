// Purpose: serialize one fixed 32-byte ACK/NACK payload into the shared frame.
// The complete response snapshot is latched before transmission; subsequent
// environment updates cannot tear a response already queued or being sent.
module mcu_frame_tx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 115200
) (
    input wire clk, input wire rst_n, input wire flush,
    input wire valid, output wire ready,
    input wire [7:0] command, input wire [15:0] sequence_id,
    input wire [255:0] payload, output wire serial_tx
);
    reg active;
    reg [5:0] index;
    reg [7:0] saved_command, byte_data;
    reg [15:0] saved_seq, crc;
    reg [255:0] saved_payload;
    wire byte_ready;
    assign ready = !active && !flush;

    // CRC is accumulated only when each version-through-payload byte transfers.
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

    // Byte indices 0..41 cover sync, six header bytes, payload, and LE CRC.
    always @* begin
        case (index)
            0: byte_data=8'h55;
            1: byte_data=8'haa;
            2: byte_data=8'h01;
            3: byte_data=saved_command;
            4: byte_data=saved_seq[7:0];
            5: byte_data=saved_seq[15:8];
            6: byte_data=8'd32;
            7: byte_data=0;
            40: byte_data=crc[7:0];
            41: byte_data=crc[15:8];
            default: byte_data=saved_payload[(index-8)*8 +: 8];
        endcase
    end
    mcu_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_uart (
        .clk(clk),.rst_n(rst_n),.flush(flush),.data(byte_data),
        .valid(active),.ready(byte_ready),.serial_tx(serial_tx));

    // A new frame can wait while the UART finishes the previous final stop bit.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; index <= 0; saved_command <= 0; saved_seq <= 0;
            saved_payload <= 0; crc <= 16'hffff;
        end else if (flush) begin active <= 0; index <= 0; end
        else if (!active) begin
            if (valid) begin
                saved_command <= command; saved_seq <= sequence_id; saved_payload <= payload;
                index <= 0; crc <= 16'hffff; active <= 1;
            end
        end else if (byte_ready) begin
            if (index >= 2 && index <= 39) crc <= crc_byte(crc,byte_data);
            if (index == 41) active <= 0;
            else index <= index+1'b1;
        end
    end
endmodule
