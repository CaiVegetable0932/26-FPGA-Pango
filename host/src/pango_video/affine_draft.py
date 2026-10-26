"""Offline affine draft compiler and sampled domain preview, never a video path."""
import math


def compile_draft(reference, geometry, angle_deg=0, translate_x=0, translate_y=0, scale=1):
    """Compose inverse image motion about the output centre with OFF rays.

    Positive angle is clockwise in y-down image space. Translation is the
    desired displayed displacement, so sampling applies its inverse. Lens
    parameters are copied unchanged. The preview is a sampled floating-point
    estimate; it is not the RTL's per-pixel validity or a calibration proof.
    """
    values = (angle_deg, translate_x, translate_y, scale)
    if any(type(v) not in (int, float) or not math.isfinite(v) for v in values):
        raise ValueError('变换参数必须是有限数值')
    if not -180 <= angle_deg <= 180 or not .25 <= scale <= 4 or max(abs(translate_x), abs(translate_y)) > 4096:
        raise ValueError('变换超出编辑范围')
    width, height = reference['width'], reference['height']
    cx, cy = (width - 1) / 2, (height - 1) / 2
    c, s = math.cos(math.radians(angle_deg)) / scale, math.sin(math.radians(angle_deg)) / scale
    inverse = (c, s, cx-c*(cx+translate_x)-s*(cy+translate_y),
               -s, c, cy+s*(cx+translate_x)-c*(cy+translate_y))
    a = [v / (1 << 26) for v in reference['coefficients']]
    b = inverse
    matrix = [a[0]*b[0]+a[1]*b[3], a[0]*b[1]+a[1]*b[4], a[0]*b[2]+a[1]*b[5]+a[2],
              a[3]*b[0]+a[4]*b[3], a[3]*b[1]+a[4]*b[4], a[3]*b[2]+a[4]*b[5]+a[5]]
    result = dict(geometry)
    for name, value in zip(('a00','a01','a02','a10','a11','a12'), matrix):
        # Match the project's nearest/half-away convention for signed Q26.
        q = math.floor(abs(value)*(1 << 26)+.5) * (-1 if value < 0 else 1)
        limit = 0x20000000 if name in ('a02','a12') else 0x800000
        if abs(q) > limit:
            raise ValueError('量化矩阵超出 FPGA 系数范围')
        result[name] = q
    mask = []
    k1,k2,p1,p2 = (result[n]/(1 << 26) for n in ('k1','k2','p1','p2'))
    fx,fy,px,py = (result[n]/65536 for n in ('fx','fy','cx','cy'))
    for row in range(36):
        for col in range(64):
            u,v = col*(width-1)/63, row*(height-1)/35
            x,y = matrix[0]*u+matrix[1]*v+matrix[2], matrix[3]*u+matrix[4]*v+matrix[5]
            r2=x*x+y*y; radial=1+k1*r2+k2*r2*r2
            sx=fx*(x*radial+2*p1*x*y+p2*(r2+2*x*x))+px
            sy=fy*(y*radial+p1*(r2+2*y*y)+2*p2*x*y)+py
            mask.append(int(0 <= sx < width-1 and 0 <= sy < height-1))
    return dict(coefficients=result, preview_mask=mask, preview_width=64, preview_height=36,
                estimated_valid_fraction=sum(mask)/len(mask))
