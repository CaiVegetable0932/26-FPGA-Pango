"""Purpose: independent offline reference for the FPGA affine/Brown-Conrady path.

This model is for calibration and RTL checking, not host-side live correction.
The image's x axis points right and y axis down. A positive demo angle rotates
the displayed image clockwise; MCU angle axes and zero are not yet calibrated.
"""

from dataclasses import dataclass
from math import cos, radians, sin


@dataclass(frozen=True)
class CameraGeometry:
    """Hold source/output intrinsics and the four lens distortion terms."""

    fx: float
    fy: float
    cx: float
    cy: float
    kout_fx: float
    kout_fy: float
    kout_cx: float
    kout_cy: float
    k1: float = 0.0
    k2: float = 0.0
    p1: float = 0.0
    p2: float = 0.0

    def affine(self, clockwise_degrees: float = 0.0) -> tuple[float, ...]:
        """Compose inverse display rotation with output pixel normalization."""
        if min(self.fx, self.fy, self.kout_fx, self.kout_fy) <= 0:
            raise ValueError("focal lengths must be positive")
        c, s = cos(radians(clockwise_degrees)), sin(radians(clockwise_degrees))
        a00, a01 = c / self.kout_fx, s / self.kout_fy
        a10, a11 = -s / self.kout_fx, c / self.kout_fy
        return (a00, a01, -a00 * self.kout_cx - a01 * self.kout_cy,
                a10, a11, -a10 * self.kout_cx - a11 * self.kout_cy)

    def inverse_float(self, u: int, v: int, clockwise_degrees: float = 0.0) -> tuple[float, float]:
        """Return the floating-point source coordinate for one output pixel."""
        a00, a01, a02, a10, a11, a12 = self.affine(clockwise_degrees)
        x, y = a00*u + a01*v + a02, a10*u + a11*v + a12
        r2 = x*x + y*y
        radial = 1 + r2*(self.k1 + self.k2*r2)
        xd = x*radial + 2*self.p1*x*y + self.p2*(r2 + 2*x*x)
        yd = y*radial + self.p1*(r2 + 2*y*y) + 2*self.p2*x*y
        return self.fx*xd + self.cx, self.fy*yd + self.cy

    def fixed_words(self, clockwise_degrees: float = 0.0) -> tuple[int, ...]:
        """Quantize the 14 documented control words without hiding overflow."""
        values = self.affine(clockwise_degrees) + (self.k1, self.k2, self.p1, self.p2)
        values += (self.fx, self.fy, self.cx, self.cy)
        words = tuple(round(v * (1 << (26 if i < 10 else 16))) for i, v in enumerate(values))
        if any(not -(1 << 31) <= w < (1 << 31) for w in words):
            raise ValueError("S(32,F) geometry coefficient out of range")
        return words


def inverse_fixed(words: tuple[int, ...], u: int, v: int) -> tuple[int, int]:
    """Mirror RTL floor shifts and return signed S(*,12) source coordinates."""
    a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy = words
    mul = lambda lhs, rhs: (lhs * rhs) >> 26
    x, y = a00*u + a01*v + a02, a10*u + a11*v + a12
    xx, yy, xy = mul(x,x), mul(y,y), mul(x,y)
    r2 = xx+yy
    radial = (1 << 26) + mul(r2, k1 + mul(k2,r2))
    xd = mul(x,radial) + 2*mul(p1,xy) + mul(p2,r2 + 2*xx)
    yd = mul(y,radial) + mul(p1,r2 + 2*yy) + 2*mul(p2,xy)
    return ((fx*xd >> 30) + (cx >> 4),
            (fy*yd >> 30) + (cy >> 4))


def sample_rgb(p00: tuple[int,int,int], p10: tuple[int,int,int],
               p01: tuple[int,int,int], p11: tuple[int,int,int],
               frac_x: int, frac_y: int) -> tuple[int,int,int]:
    """Match RTL's single final rounding after 12+12 interpolation bits."""
    if not 0 <= frac_x < 4096 or not 0 <= frac_y < 4096:
        raise ValueError("fractions must be U(12,12)")
    return tuple((((4096-frac_y)*((4096-frac_x)*p00[c] + frac_x*p10[c]) +
                   frac_y*((4096-frac_x)*p01[c] + frac_x*p11[c]) + (1 << 23)) >> 24)
                 for c in range(3))
