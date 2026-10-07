// Purpose: combine the four RGB888 samples selected by geometry_inverse_map.
// The cache must return one coherent source-frame neighborhood; this block
// neither fetches DDR nor performs Bayer demosaicing or enhancement.
module geometry_bilinear_rgb (
    input wire clk, rst_n, sample_valid, source_valid,
    input wire [11:0] frac_x, frac_y,
    input wire [23:0] p00, p10, p01, p11,
    output reg pixel_valid, output reg [23:0] pixel,
    output reg pixel_source_valid
);
    // Purpose: retain all 24 fractional bits through both interpolation axes;
    // round once at the output, matching the fixed-point reference model.
    function [7:0] blend;
        input [7:0] a,b,c,d;
        input [11:0] fx,fy;
        reg [19:0] top, bottom;
        reg [31:0] weighted;
        begin
            top = (13'd4096-{1'b0,fx})*a + {1'b0,fx}*b;
            bottom = (13'd4096-{1'b0,fx})*c + {1'b0,fx}*d;
            weighted = (13'd4096-{1'b0,fy})*top + {1'b0,fy}*bottom + 32'd8388608;
            blend = weighted[31:24];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pixel_valid<=0;pixel_source_valid<=0;pixel<=0;end
        else begin
            pixel_valid<=sample_valid;
            pixel_source_valid<=sample_valid && source_valid;
            pixel<=0;
            if (sample_valid && source_valid) begin
                pixel[23:16]<=blend(p00[23:16],p10[23:16],p01[23:16],p11[23:16],frac_x,frac_y);
                pixel[15:8]<=blend(p00[15:8],p10[15:8],p01[15:8],p11[15:8],frac_x,frac_y);
                pixel[7:0]<=blend(p00[7:0],p10[7:0],p01[7:0],p11[7:0],frac_x,frac_y);
            end
        end
    end
endmodule
