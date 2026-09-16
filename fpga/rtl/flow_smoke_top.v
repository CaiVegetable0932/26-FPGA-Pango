`timescale 1ns/1ps
// Offline flow baseline, inspired by the MINI 2_7_key_led_test example.
// Uses only the cross-checked LED0 pin. 32 cycles/toggle accelerates gate tests.
// rstn/key are asynchronous board buttons: only the second synchronizer stage
// controls functional state. Mechanical button debounce is outside this test.
module flow_smoke_top (
    input wire clk,
    input wire rstn,
    input wire key,
    output reg led0 = 1'b0
);
    (* syn_preserve = 1, syn_srlstyle = "registers" *) reg rst_meta = 1'b0;
    (* syn_preserve = 1, syn_srlstyle = "registers" *) reg rst_sync = 1'b0;
    (* syn_preserve = 1, syn_srlstyle = "registers" *) reg key_meta = 1'b1;
    (* syn_preserve = 1, syn_srlstyle = "registers" *) reg key_sync = 1'b1;
    reg [4:0] tick_count = 5'd0;

    always @(posedge clk) begin
        rst_meta <= rstn;
        rst_sync <= rst_meta;
        key_meta <= key;
        key_sync <= key_meta;
        if (!rst_sync) begin
            tick_count <= 5'd0;
            led0 <= 1'b0;
        end else begin
            tick_count <= tick_count + 5'd1;
            if ((tick_count == 5'd31) && key_sync)
                led0 <= ~led0;
        end
    end
endmodule
