"""Algorithm 06 golden contract: integer pixel centres, RGB888 and checked arithmetic.

This module is an offline reference, never a PC video forwarding/correction path.
Rounding is floor((value + 2**(shift-1))/2**shift), including signed ties.
"""
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import numpy as np


def rnd(value, shift):
    """Round once, ties toward positive infinity; arithmetic shift preserves floor."""
    return (value + (1 << (shift - 1))) >> shift if shift else value


def quant(value, bits, frac):
    """Reject coefficient overflow rather than silently clipping a calibration."""
    q = math.floor(value * (1 << frac) + 0.5)
    if not -(1 << (bits - 1)) <= q < (1 << (bits - 1)):
        raise ValueError(f"S({bits},{frac}) coefficient overflow: {value}")
    return q


@dataclass(frozen=True)
class Calibration:
    """Immutable model entity; retain original source status independently of precision."""
    width: int
    height: int
    intrinsic: tuple
    distortion: tuple
    affine: tuple
    source_sha256: str = "synthetic"
    source_status: str = "unit_test"

    @classmethod
    def load(cls, path, angle=0.0):
        """Accept only the frozen four-coefficient pinhole model, no fisheye substitution."""
        raw = Path(path).read_bytes()
        entity = json.loads(raw)
        if entity['model'] != 'pinhole_k1_k2_p1_p2' or entity.get('k3', 0) != 0:
            raise ValueError('unsupported lens model')
        k, d = entity['K'], entity['D']
        if len(d) != 4 or k[0][1] != 0 or k[1][0] != 0:
            raise ValueError('unsupported coefficient/skew layout')
        fx, fy, cx, cy = k[0][0], k[1][1], k[0][2], k[1][2]
        if fx <= 0 or fy <= 0:
            raise ValueError('focal length must be positive')
        # Positive displayed angle is clockwise (screen v points down); inverse
        # rotation acts in normalized ray space around the calibrated principal point.
        c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))
        a = (c/fx, s/fy, -c*cx/fx-s*cy/fy,
             -s/fx, c/fy, s*cx/fx-c*cy/fy)
        return cls(*entity['image_size'], (fx, fy, cx, cy), tuple(d), a,
                   hashlib.sha256(raw).hexdigest(), entity.get('status', 'unverified'))

    def coefficients(self):
        """Hardware register order: affine, distortion, input intrinsics."""
        return tuple(quant(v, 32, 26) for v in self.affine + self.distortion) + tuple(
            quant(v, 32, 16) for v in self.intrinsic)


def lens_float(x, y, c):
    """Brown-Conrady inverse sampling from normalized ideal rays to distorted source."""
    k1, k2, p1, p2 = c.distortion
    fx, fy, cx, cy = c.intrinsic
    r2 = x*x + y*y
    radial = 1 + r2*(k1+k2*r2)
    return (fx*(x*radial+2*p1*x*y+p2*(r2+2*x*x))+cx,
            fy*(y*radial+p1*(r2+2*y*y)+2*p2*x*y)+cy)


def map_float(u, v, c):
    """Integer centres; affine already contains Kout and inverse screen rotation."""
    a = c.affine
    return lens_float(a[0]*u+a[1]*v+a[2], a[3]*u+a[4]*v+a[5], c)


def lens_fixed(x, y, c, prior_ok=True):
    """Stage-by-stage RTL golden with full products and checked signed narrowing.

    x/y S(24,20); squares/r2 S(32,20); Horner/radial S(32,26);
    tangential and distorted rays S(32,20); final coordinates S(28,12).
    int64 suffices for the accepted stage ranges; rejected lanes are zeroed before
    later products so overflow inputs cannot contaminate the reference itself.
    """
    _, _, _, _, _, _, k1, k2, p1, p2, fx, fy, cx, cy = c.coefficients()
    ok = np.broadcast_to(prior_ok, np.broadcast(x, y).shape).copy()
    stages = {}

    def checked(name, value, bits=32):
        nonlocal ok
        valid = (value >= -(1 << (bits-1))) & (value < (1 << (bits-1)))
        ok = ok & valid
        stages[name] = np.where(ok, value, 0)
        return stages[name]

    x, y = checked('x', x, 24), checked('y', y, 24)
    xx = checked('xx', rnd(x*x, 20))
    yy = checked('yy', rnd(y*y, 20))
    xy = checked('xy', rnd(x*y, 20))
    r2 = checked('r2', xx+yy)
    t = checked('horner', rnd(r2*k2, 20)+k1)
    tx = checked('tx', rnd(xy*p1, 26)*2 + rnd((r2+2*xx)*p2, 26))
    ty = checked('ty', rnd(xy*p2, 26)*2 + rnd((r2+2*yy)*p1, 26))
    radial = checked('radial', (1 << 26)+rnd(r2*t, 20))
    xd = checked('xd', rnd(x*radial, 26)+tx)
    yd = checked('yd', rnd(y*radial, 26)+ty)
    ud = checked('ud', rnd(xd*fx+(cx << 20), 24), 28)
    vd = checked('vd', rnd(yd*fy+(cy << 20), 24), 28)
    mask = ok & (ud >= 0) & (vd >= 0) & (ud <= (c.width-1)*4096) & (vd <= (c.height-1)*4096)
    return ud, vd, mask, ok, stages


def map_fixed(u, v, c):
    """Quantized affine baseline; exact integer recurrence must match this result."""
    a = c.coefficients()[:6]
    ax, ay = a[0]*u+a[1]*v+a[2], a[3]*u+a[4]*v+a[5]
    ok = (abs(ax) < (1 << 39)) & (abs(ay) < (1 << 39))
    return lens_fixed(rnd(ax, 6), rnd(ay, 6), c, ok)


def reciprocal_fixed(denominator):
    """Normalized 256-entry midpoint LUT, two Newton steps, exponent recovery.

    Input S(40,26), positive camera depth only, near-zero threshold 2**-12.
    Mantissa U(31,30) in [1,2), reciprocal U(31,30) in (0.5,1].
    Return U(48,34) reciprocal and explicit rejection for nonpositive/overflow.
    Eight extra fractional bits after exponent recovery bound final output
    quantization over the entire signed40 depth domain, matching board RTL.
    """
    if denominator < (1 << 14) or denominator >= (1 << 39):
        return 0, False
    exponent = denominator.bit_length()-1-26
    shift = 4-exponent
    m = denominator << shift if shift >= 0 else rnd(denominator, -shift)
    if m >= (2 << 30):
        m = 1 << 30
        exponent += 1
    index = min(255, (m-(1 << 30)) >> 22)
    # Integer midpoint seed is byte-for-byte the elaborated native ROM table.
    divisor = 513+2*index
    r = ((1 << 39)+divisor//2)//divisor
    for _ in range(2):
        mr = rnd(m*r, 30)
        r = rnd(r*((2 << 30)-mr), 30)
    shift = exponent-4
    result = rnd(r, shift) if shift > 0 else r << -shift
    return result, 0 <= result < (1 << 47)


def perspective_fixed(u, v, matrix, c):
    """Scalar projective golden; compose ideal-ray matrix before lens evaluation."""
    q = [sum(quant(row[i], 32, 26)*p for i, p in enumerate((u, v, 1))) for row in matrix]
    if any(not -(1 << 39) <= x < (1 << 39) for x in q):
        return 0, 0, False, False, {}
    inv, ok = reciprocal_fixed(q[2])
    x, y = rnd(q[0]*inv, 40), rnd(q[1]*inv, 40)
    return lens_fixed(np.int64(x), np.int64(y), c, ok)


def reflect101(index, extent):
    """One-pixel border reflection preserves Bayer colour parity; dimensions >=2."""
    if extent < 2:
        raise ValueError('Bayer dimension must be at least two')
    return 1 if index < 0 else extent-2 if index >= extent else index


def colour(x, y, bayer):
    """Register encoding 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR; R,Gr,Gb,B=0,1,2,3."""
    return ((y & 1)*2+(x & 1)) ^ bayer


def isp_fixed(raw, bayer=0, black=(0,0,0,0), gains=(4096,)*4, matrix=None):
    """RAW8 -> 12-bit corrected Bayer -> reflect101 bilinear -> optional CCM -> RGB888.

    Gain U(16,12), CCM S(18,14), identity default is a test curve, not calibrated colour.
    """
    h, w = raw.shape
    if h < 2 or w < 2 or bayer not in range(4):
        raise ValueError('unsupported Bayer shape/phase')
    corrected = np.zeros((h,w), dtype=np.int64)
    for y in range(h):
        for x in range(w):
            k = colour(x,y,bayer)
            corrected[y,x] = min(4095, rnd(max(0,int(raw[y,x])-black[k])*gains[k], 8))
    rgb = np.zeros((h,w,3), dtype=np.uint8)
    for y in range(h):
        for x in range(w):
            a = [[int(corrected[reflect101(y+j,h), reflect101(x+i,w)]) for i in (-1,0,1)] for j in (-1,0,1)]
            center, cross, diagonal = a[1][1], rnd(a[0][1]+a[1][0]+a[1][2]+a[2][1],2), rnd(a[0][0]+a[0][2]+a[2][0]+a[2][2],2)
            horizontal, vertical = rnd(a[1][0]+a[1][2],1), rnd(a[0][1]+a[2][1],1)
            k = colour(x,y,bayer)
            p = (center,cross,diagonal) if k==0 else (diagonal,cross,center) if k==3 else (horizontal,center,vertical) if k==1 else (vertical,center,horizontal)
            if matrix is not None:
                # CCM keeps full linear products until the final RGB888 rounding,
                # matching rgb_colour_matrix instead of rounding twice at 12 bits.
                rgb[y,x] = [min(255,max(0,rnd(sum(int(a)*int(b) for a,b in zip(row,p)),18))) for row in matrix]
            else:
                rgb[y,x] = [min(255,max(0,rnd(ch,4))) for ch in p]
    return rgb


def bilinear(samples, a, b):
    """P00,P10,P01,P11, RGB channels; preserve horizontal U(20,12)."""
    s = np.asarray(samples,dtype=np.int64)
    top, bot = (4096-a)*s[0]+a*s[1], (4096-a)*s[2]+a*s[3]
    return np.clip(rnd((4096-b)*top+b*bot,24),0,255).astype(np.uint8)


def sample_rgb(image, u, v, mode=0, lut=None):
    """Closed valid domain; floor signed coordinates before clamping neighbours."""
    h,w,_ = image.shape
    if not 0 <= u <= (w-1)*4096 or not 0 <= v <= (h-1)*4096:
        return np.zeros(3,dtype=np.uint8),False
    x,y,a,b = u//4096,v//4096,u%4096,v%4096
    neighbours = image[[y,y,min(y+1,h-1),min(y+1,h-1)], [x,min(x+1,w-1),x,min(x+1,w-1)]]
    if mode not in range(3) or (mode and lut is None):
        raise ValueError('invalid enhancement contract')
    if mode==1:
        neighbours = np.asarray(lut)[neighbours]
    p = bilinear(neighbours,a,b)
    return (np.asarray(lut,dtype=np.uint8)[p] if mode==2 else p),True


class TileCacheModel:
    """Transaction oracle for 4-way cache; counts actual aligned row-span bus bytes.

    Lines become valid only after complete fills. Current four tiles are pinned
    during replacement. Ordered single outstanding refill is the conservative
    RTL baseline; this model is not a memory-controller throughput measurement.
    """
    def __init__(self, width, height, tile=(16,16), sets=32, ways=4, stride=None, replacement='round_robin'):
        self.width,self.height,self.tw,self.th = width,height,*tile
        self.sets,self.ways,self.stride = sets,ways,stride or width*3
        if replacement not in ('round_robin','lru'):raise ValueError('unsupported replacement')
        self.replacement=replacement
        self.lines = [[] for _ in range(sets)] if replacement=='lru' else [[None]*ways for _ in range(sets)]
        self.rr=[0]*sets
        self.misses,self.hits,self.bus_bytes,self.duplicates = 0,0,0,0

    def access(self, u, v):
        """Merge duplicates; default pinned round robin matches RTL exactly (LRU comparison optional)."""
        if not 0 <= u <= (self.width-1)*4096 or not 0 <= v <= (self.height-1)*4096:
            return
        x,y = u//4096,v//4096
        pixels = ((x,y),(min(x+1,self.width-1),y),(x,min(y+1,self.height-1)),(min(x+1,self.width-1),min(y+1,self.height-1)))
        self.duplicates += 4-len(set(pixels))
        tiles = list(dict.fromkeys((px//self.tw,py//self.th) for px,py in pixels))
        for tx,ty in tiles:
            # XOR mixes tile rows and columns without assuming power-of-two width.
            set_index=(tx ^ ty)%self.sets
            line = self.lines[set_index]
            key = (tx,ty)
            if key in line:
                self.hits += 1
                if self.replacement=='lru':line.remove(key)
            else:
                self.misses += 1
                if self.replacement=='round_robin':
                    victim=next((self.rr[set_index]+i)%self.ways for i in range(self.ways)
                                if line[(self.rr[set_index]+i)%self.ways] not in tiles)
                    line[victim]=key;self.rr[set_index]=(victim+1)%self.ways
                elif len(line)==self.ways:
                    victim = next(k for k in line if k not in tiles)
                    line.remove(victim)
                columns = min(self.tw,self.width-tx*self.tw)
                for row in range(ty*self.th,min((ty+1)*self.th,self.height)):
                    addr = row*self.stride+tx*self.tw*3
                    self.bus_bytes += ((addr%32+columns*3+31)//32)*32
            if self.replacement=='lru':line.append(key)
