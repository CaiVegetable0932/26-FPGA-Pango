`timescale 1ns/1ps
module reset_sync #(parameter STAGES = 3)(input wire clk, input wire async_reset_n, output wire reset_n);
    (* syn_preserve = 1 *) reg [STAGES-1:0] stages;
    always @(posedge clk or negedge async_reset_n)
        if (!async_reset_n) stages <= {STAGES{1'b0}};
        else stages <= {stages[STAGES-2:0], 1'b1};
    assign reset_n = stages[STAGES-1];
endmodule
