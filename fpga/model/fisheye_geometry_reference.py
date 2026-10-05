"""Independent analytic reference and parameter encoder, never a live PC warp.

The FPGA accepts affine/K/D words, not this model's per-pixel coordinates.
Q26 words describe ideal rays and lens terms; Q16 words describe pixel intrinsics.
"""
from dataclasses import dataclass
from math import atan, cos, isfinite, radians, sin, sqrt, tan


@dataclass(frozen=True)
class Lens:
    """Freeze one source camera and output virtual camera parameter set."""
    width: int = 1920
    height: int = 1080
    fx: float = 770
    fy: float = 752
    cx: float = 945
    cy: float = 553
    k1: float = .121
    k2: float = -.118
    k3: float = 0
    k4: float = .036
    output_fov_deg: float = 139
    rotation_deg: float = 0
    model: int = 2

    def words(self):
        """Compose inverse in-plane rotation/Kout and quantize ONLY parameters."""
        if self.model not in (0, 1, 2) or self.width < 2 or self.height < 2:
            raise ValueError("unsupported mode")
        if not 1 <= self.output_fov_deg <= 170 or min(self.fx, self.fy) <= 0:
            raise ValueError("invalid intrinsics/FOV")
        f = self.width / (2 * tan(radians(self.output_fov_deg)/2))
        ox, oy = (self.width-1)/2, (self.height-1)/2
        c, s = cos(radians(self.rotation_deg)), sin(radians(self.rotation_deg))
        # Positive display rotation is clockwise; sample its inverse ray.
        affine = (c/f, s/f, -(c*ox+s*oy)/f,
                  -s/f, c/f, (s*ox-c*oy)/f)
        values = (*affine, self.k1, self.k2, self.k3, self.k4,
                  self.fx, self.fy, self.cx, self.cy)
        result = []
        for i, value in enumerate(values):
            if not isfinite(value):
                raise ValueError("non-finite parameter")
            q = round(value * (1 << (26 if i < 10 else 16)))
            if not -(1 << 31) <= q < (1 << 31):
                raise ValueError("fixed-point overflow")
            result.append(q)
        return tuple(result)


def radial_scale(model, r2, coefficients):
    """Analytic Brown radial or equidistant four-term fisheye scale."""
    k1, k2, k3, k4 = coefficients
    if model == 0:
        return 1.0
    if model == 1:
        return 1 + k1*r2 + k2*r2*r2
    if r2 == 0:
        return 1.0
    r = sqrt(r2)
    theta = atan(r)
    t2 = theta*theta
    return theta/r * (1 + t2*(k1+t2*(k2+t2*(k3+t2*k4))))


def source_coordinate(words, model, x, y):
    """Map one output pixel analytically with quantized input parameters."""
    if model == 0:
        return float(x), float(y)
    a = [w/(1 << 26) for w in words[:10]]
    fx, fy, cx, cy = (w/(1 << 16) for w in words[10:])
    nx, ny = a[0]*x+a[1]*y+a[2], a[3]*x+a[4]*y+a[5]
    if abs(nx) > 4 or abs(ny) > 4 or nx*nx+ny*ny >= 32:
        return None
    r2 = nx*nx+ny*ny
    scale = radial_scale(model, r2, a[6:10])
    tx = 2*a[8]*nx*ny+a[9]*(r2+2*nx*nx) if model == 1 else 0
    ty = a[8]*(r2+2*ny*ny)+2*a[9]*nx*ny if model == 1 else 0
    return fx*(nx*scale+tx)+cx, fy*(ny*scale+ty)+cy


def tone(value):
    """Match the continuous FPGA curve without destination-order median state."""
    if value <= 24: bright = 0
    elif value <= 80: bright = (value-24)*2
    elif value <= 144: bright = 112+value-80+((value-80) >> 2)
    elif value == 255: bright = 255
    else: bright = 192+((value-144) >> 1)+((value-144) >> 4)+((value-144) >> 6)
    if value <= 8: dark = 0
    elif value <= 16: dark = (value-8)*4
    elif value <= 32: dark = 32+(value-16)*7
    elif value <= 64: dark = 144+(value-32)*2
    elif value <= 128: dark = 208+((value-64) >> 1)
    elif value <= 240: dark = 240+((value-128) >> 4)
    elif value == 255: dark = 255
    else: dark = 247+((value-240) >> 1)
    return (bright+dark+1) >> 1


def sample_gray(image, xq, yq, enhance=False):
    """Reference causal Bayer box -> single rounded 12-bit bilinear result."""
    h, w = len(image), len(image[0])
    if not 0 <= xq <= (w-1)*4096 or not 0 <= yq <= (h-1)*4096:
        return 0, False
    x, y = xq >> 12, yq >> 12
    x1, y1 = min(x+1, w-1), min(y+1, h-1)
    def gray(px, py):
        values = [image[sy][sx] for sy in (max(0, py-1), py)
                  for sx in (max(0, px-1), px)]
        return (sum(map(tone, values) if enhance else values)+2) >> 2
    a, b, c, d = gray(x, y), gray(x1, y), gray(x, y1), gray(x1, y1)
    fx, fy = xq & 4095, yq & 4095
    weighted = ((4096-fy)*((4096-fx)*a+fx*b) +
                fy*((4096-fx)*c+fx*d) + (1 << 23))
    return weighted >> 24, True
