`timescale 1ns/1ps
// Purpose: restart the MINI native IOCLKDIV/OSERDES startup sequence after
// external reset or PLL unlock. ref_clk is the free-running 27 MHz reference;
// pixel_clk is the native /5 output, never a logic-gated clock.
// The 0x4f..0x8f active-low pulse and 0xff settling point are retained from
// the installed PG2L100H high-speed-output example, not shortened for throughput.
module video_clock_start(
    input wire ref_clk, input wire pixel_clk, input wire async_reset_n,
    output wire reference_reset_n,
    (* syn_preserve = 1 *) output reg divider_reset_n,
    output wire clock_ready, output wire pixel_reset_n
);
    // Unlock asserts immediately even if either clock stops. Re-lock first
    // crosses a three-stage reference-domain chain before starting the counter.
    reset_sync rs_ref(ref_clk, async_reset_n, reference_reset_n);
    (* syn_preserve = 1 *) reg [7:0] start_count;
    always @(posedge ref_clk or negedge reference_reset_n)
        if (!reference_reset_n) start_count <= 8'h00;
        else if (start_count != 8'hff) start_count <= start_count + 1'b1;

    // Dedicated startup register fans out ONLY to divider/serializer reset.
    // Its async initialization is high as in the vendor sequence; the low
    // pulse is emitted once per lock episode, while pixel consumers stay reset.
    always @(posedge ref_clk or negedge reference_reset_n)
        if (!reference_reset_n) divider_reset_n <= 1'b1;
        else divider_reset_n <= !((start_count >= 8'h4f) && (start_count <= 8'h8f));
    assign clock_ready = (start_count == 8'hff);

    // Only stage zero samples the reference-domain ready level. All later
    // stages and consumer recovery/removal remain timed in the pixel domain.
    // Async assertion clears stale readiness with pixel_clk stopped; release
    // requires three pixel edges after the entire native startup completes.
    (* syn_preserve = 1 *) reg pixel_ready_meta;
    (* syn_preserve = 1 *) reg [1:0] pixel_stages;
    always @(posedge pixel_clk or negedge reference_reset_n)
        if (!reference_reset_n) begin
            pixel_ready_meta <= 1'b0;
            pixel_stages <= 2'b00;
        end else begin
            pixel_ready_meta <= clock_ready;
            pixel_stages <= {pixel_stages[0], pixel_ready_meta};
        end
    assign pixel_reset_n = pixel_stages[1];
endmodule
