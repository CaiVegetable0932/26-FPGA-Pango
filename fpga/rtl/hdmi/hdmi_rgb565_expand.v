// Purpose: full-range RGB565 to RGB888 conversion without pipeline latency.
// Replicate high bits instead of zero-padding, so white maps to 0xffffff.
module hdmi_rgb565_expand(input wire [15:0] rgb565, output wire [23:0] rgb888);
    assign rgb888 = {rgb565[15:11], rgb565[15:13],
                     rgb565[10:5], rgb565[10:9],
                     rgb565[4:0], rgb565[4:2]};
endmodule
