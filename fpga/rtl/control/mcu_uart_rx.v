// Purpose: synthesizable 8N1 receiver with a two-register input synchronizer.
// Clock/baud division is rounded; require CLK_HZ/BAUD >= 8. A bad stop bit
// raises one error and waits for idle high, so a break cannot become bytes.
module mcu_uart_rx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 115200
) (
    input wire clk, input wire rst_n, input wire flush, input wire serial_rx,
    output reg [7:0] data, output reg valid, output reg framing_error
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer HALF = DIV / 2;
    localparam [2:0] IDLE=0, START=1, DATA=2, STOP=3, WAIT_HIGH=4;
    // Preserve both physical CDC stages so first-stage-only board constraints
    // cannot be invalidated by merging equivalent boot/MCU UART synchronizers.
    (* syn_preserve=1, ASYNC_REG="TRUE" *) reg rx_meta, rx_sync;
    reg [2:0] state, bit_index;
    reg [31:0] ticks;
    reg [7:0] shift;

    // Only these two registers sample the asynchronous pin; logic uses rx_sync.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else begin rx_meta <= serial_rx; rx_sync <= rx_meta; end
    end

    // Validate the start center, sample data centers LSB first, then check stop.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; ticks <= 0; bit_index <= 0; shift <= 0;
            data <= 0; valid <= 0; framing_error <= 0;
        end else begin
            valid <= 0; framing_error <= 0;
            if (flush) begin state <= WAIT_HIGH; ticks <= 0; end
            else case (state)
                IDLE: if (!rx_sync) begin state <= START; ticks <= HALF-1; end
                START: if (ticks != 0) ticks <= ticks-1'b1;
                    else if (rx_sync) state <= IDLE;
                    else begin state <= DATA; ticks <= DIV-1; bit_index <= 0; end
                DATA: if (ticks != 0) ticks <= ticks-1'b1;
                    else begin
                        shift[bit_index] <= rx_sync; ticks <= DIV-1;
                        if (bit_index == 7) state <= STOP;
                        else bit_index <= bit_index+1'b1;
                    end
                STOP: if (ticks != 0) ticks <= ticks-1'b1;
                    else if (rx_sync) begin data <= shift; valid <= 1; state <= IDLE; end
                    else begin framing_error <= 1; state <= WAIT_HIGH; end
                WAIT_HIGH: if (rx_sync) state <= IDLE;
                default: state <= WAIT_HIGH;
            endcase
        end
    end
endmodule
