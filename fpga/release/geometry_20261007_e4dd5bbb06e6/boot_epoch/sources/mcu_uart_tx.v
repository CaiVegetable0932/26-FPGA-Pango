// Purpose: bounded 8N1 transmitter. A byte transfers on valid && ready;
// the stop bit lasts a full rounded baud period and flush returns idle high.
module mcu_uart_tx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 115200
) (
    input wire clk, input wire rst_n, input wire flush,
    input wire [7:0] data, input wire valid,
    output wire ready, output reg serial_tx
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    reg busy;
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg [31:0] ticks;
    assign ready = !busy && !flush;

    // Shift start/data/stop at bit boundaries, preserving input until transfer.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0; serial_tx <= 1; shift <= 10'h3ff; ticks <= 0; bit_index <= 0;
        end else if (flush) begin busy <= 0; serial_tx <= 1; end
        else if (!busy) begin
            if (valid) begin
                shift <= {1'b1, data, 1'b0}; serial_tx <= 0;
                busy <= 1; ticks <= DIV-1; bit_index <= 0;
            end
        end else if (ticks != 0) ticks <= ticks-1'b1;
        else if (bit_index == 9) begin busy <= 0; serial_tx <= 1; end
        else begin
            shift <= {1'b1, shift[9:1]}; serial_tx <= shift[1];
            ticks <= DIV-1; bit_index <= bit_index+1'b1;
        end
    end
endmodule
