`timescale 1ns/1ps
// Purpose: explicit board self-test source, never an ISP/camera substitute.
// Produces the same 720p60 raster and moving signature validated via Hagibis.
module hdmi_720p_diagnostic(
    input wire pixel_clk, input wire reset_n,
    output wire [23:0] rgb, output wire de, output wire hs, output wire vs
);
    wire [11:0] x, y;
    reg vs_previous;
    reg [31:0] frame_counter;
    sync_vg u_timing(.clk(pixel_clk), .rstn(reset_n),
        .x_act(x), .y_act(y), .de_out(de), .hs_out(hs), .vs_out(vs), .de_re());
    // Count complete raster transitions for the visible moving frame signature.
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin vs_previous <= 0; frame_counter <= 0; end
        else begin
            vs_previous <= vs;
            if (vs && !vs_previous) frame_counter <= frame_counter + 1'b1;
        end
    end
    hdmi_test_pattern u_pattern(.active_video(de), .x(x), .y(y),
        .frame_counter(frame_counter), .rgb(rgb));
endmodule
