// Purpose: map one output pixel back to a source pixel with the planned
// affine + radial/tangential lens model. Inputs are frame-stable parameters.
// This correctness-first one-request-per-clock block is not yet a timed
// 1080p30 pipeline or a DDR reader; its output feeds a future tile cache.
module geometry_inverse_map #(
    parameter integer WIDTH = 1920,
    parameter integer HEIGHT = 1080
) (
    input wire clk, rst_n, request_valid,
    input wire [11:0] output_x, output_y,
    // Six signed S(32,26) output-pixel -> ideal normalized coefficients.
    input wire signed [31:0] a00, a01, a02, a10, a11, a12,
    // Signed S(32,26) Brown-Conrady coefficients.
    input wire signed [31:0] k1, k2, p1, p2,
    // Signed S(32,16) input-camera focal lengths and principal point.
    input wire signed [31:0] fx, fy, cx, cy,
    output reg result_valid, source_valid,
    output reg [11:0] x0, x1, y0, y1,
    output reg [11:0] frac_x, frac_y
);
    localparam signed [63:0] ONE = 64'sd67108864; // 1 in S(*,26).
    localparam signed [63:0] NORM_LIMIT = 64'sd268435456; // |x,y| <= 4.
    localparam signed [63:0] X_MAX_Q12 = (WIDTH-1) * 64'sd4096;
    localparam signed [63:0] Y_MAX_Q12 = (HEIGHT-1) * 64'sd4096;

    // Purpose: retain the full signed product before the Q26 shift. The
    // supported parameter domain is checked by the separate control bank;
    // spatial bounds are checked here before narrowing to 12-bit indices.
    function signed [63:0] mul26;
        input signed [63:0] lhs, rhs;
        reg signed [127:0] product;
        begin product = lhs * rhs; mul26 = product >>> 26; end
    endfunction

    wire signed [63:0] xq = $signed(a00)*$signed({1'b0,output_x}) +
                              $signed(a01)*$signed({1'b0,output_y}) + $signed(a02);
    wire signed [63:0] yq = $signed(a10)*$signed({1'b0,output_x}) +
                              $signed(a11)*$signed({1'b0,output_y}) + $signed(a12);
    wire norm_ok = xq >= -NORM_LIMIT && xq <= NORM_LIMIT &&
                   yq >= -NORM_LIMIT && yq <= NORM_LIMIT;
    wire signed [63:0] xx = mul26(xq,xq);
    wire signed [63:0] yy = mul26(yq,yq);
    wire signed [63:0] xy = mul26(xq,yq);
    wire signed [63:0] r2 = xx + yy;
    wire signed [63:0] radial = ONE + mul26(r2,$signed(k1) + mul26($signed(k2),r2));
    wire signed [63:0] xd = mul26(xq,radial) + 2*mul26($signed(p1),xy) +
                            mul26($signed(p2),r2 + 2*xx);
    wire signed [63:0] yd = mul26(yq,radial) + mul26($signed(p1),r2 + 2*yy) +
                            2*mul26($signed(p2),xy);
    // Purpose: signed arithmetic shifts implement floor for negative source
    // coordinates. Both focal and distortion products remain 128-bit until
    // converted to S(*,12) pixel coordinates.
    wire signed [127:0] uq_full = ($signed(fx)*$signed(xd)) >>> 30;
    wire signed [127:0] vq_full = ($signed(fy)*$signed(yd)) >>> 30;
    wire signed [127:0] uq = uq_full + ($signed(cx) >>> 4);
    wire signed [127:0] vq = vq_full + ($signed(cy) >>> 4);
    wire bounds_ok = norm_ok && fx > 0 && fy > 0 &&
                     uq >= 0 && vq >= 0 && uq <= X_MAX_Q12 && vq <= Y_MAX_Q12;
    wire [11:0] ix = uq[23:12];
    wire [11:0] iy = vq[23:12];

    // Purpose: preserve the final row/column by repeating their neighbor;
    // invalid mappings produce a black-mask request, never a DDR address.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 0; source_valid <= 0;
            x0 <= 0; x1 <= 0; y0 <= 0; y1 <= 0; frac_x <= 0; frac_y <= 0;
        end else begin
            result_valid <= request_valid;
            source_valid <= request_valid && bounds_ok;
            x0 <= 0; x1 <= 0; y0 <= 0; y1 <= 0; frac_x <= 0; frac_y <= 0;
            if (request_valid && bounds_ok) begin
                x0 <= ix; x1 <= ix == WIDTH-1 ? ix : ix+1'b1;
                y0 <= iy; y1 <= iy == HEIGHT-1 ? iy : iy+1'b1;
                frac_x <= uq[11:0]; frac_y <= vq[11:0];
            end
        end
    end
endmodule
