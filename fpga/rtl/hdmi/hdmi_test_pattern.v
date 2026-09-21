`timescale 1ns/1ps
// Purpose: generate a self-identifying 1280x720 RGB888 HDMI diagnostic image.
// The fixed eight-color bars verify channel order and active-raster geometry;
// the frame signature and moving square prove that the captured stream is live.
module hdmi_test_pattern(
    input  wire        active_video,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [31:0] frame_counter,
    output reg  [23:0] rgb
);
    reg [23:0] base_color;
    reg [11:0] moving_x;

    // Purpose: use eight equal 160-pixel bars in RGB order so a capture can be
    // checked numerically without relying only on a visual inspection.
    always @(*) begin
        if      (x < 12'd160)  base_color = 24'hffffff;
        else if (x < 12'd320)  base_color = 24'hffff00;
        else if (x < 12'd480)  base_color = 24'h00ffff;
        else if (x < 12'd640)  base_color = 24'h00ff00;
        else if (x < 12'd800)  base_color = 24'hff00ff;
        else if (x < 12'd960)  base_color = 24'hff0000;
        else if (x < 12'd1120) base_color = 24'h0000ff;
        else                   base_color = 24'h000000;
    end

    // Purpose: advance a 96-pixel marker in 16-pixel steps. The lower six
    // frame bits keep the marker inside the active width without a divider.
    always @(*) moving_x = {2'b00, frame_counter[5:0], 4'b0000};

    always @(*) begin
        rgb = 24'h000000;
        if (active_video) begin
            rgb = base_color;

            // A white border makes blanking/cropping errors obvious.
            if ((x < 12'd4) || (x >= 12'd1276) ||
                (y < 12'd4) || (y >= 12'd716))
                rgb = 24'hffffff;

            // Encode frame_counter[15:0] as sixteen 32x64 cells at the top.
            // Dark cells remain visible against the white/yellow/cyan bars.
            if ((y >= 12'd32) && (y < 12'd96) && (x < 12'd512)) begin
                if (frame_counter[x[8:5]]) rgb = 24'hffffff;
                else                       rgb = 24'h202020;
            end

            // The moving square changes every source frame and inverts the
            // underlying bar, giving the host a robust dynamic-frame signal.
            if ((y >= 12'd560) && (y < 12'd656) &&
                (x >= moving_x) && (x < moving_x + 12'd96))
                rgb = base_color ^ 24'hffffff;

            // Fixed white reference line assists geometry measurements.
            if ((y >= 12'd358) && (y < 12'd362)) rgb = 24'hffffff;
        end
    end
endmodule
