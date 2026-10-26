"""Independent floating point references for limited affine motion and history.

These functions are offline calibration/verification tools. They are not a PC
runtime video path, and neither a nonzero ID nor passing synthetic tests proves
physical camera/MCU calibration.
"""
from __future__ import annotations

import math
from dataclasses import dataclass


def pose_affine(reference, pitch_rate, yaw_rate, pitch_mdeg, yaw_mdeg,
                reference_pitch_mdeg, reference_yaw_mdeg, domain):
    """Use the declared mechanical angular domain; normalized XYZ is excluded."""
    pmin, pmax, ymin, ymax = domain
    if not (pmin <= pitch_mdeg <= pmax and ymin <= yaw_mdeg <= ymax):
        raise ValueError("mechanical angle outside calibrated domain")
    p = math.radians((pitch_mdeg-reference_pitch_mdeg)/1000)
    y = math.radians((yaw_mdeg-reference_yaw_mdeg)/1000)
    return tuple(a+jp*p+jy*y for a, jp, jy in zip(reference, pitch_rate, yaw_rate))


def compose(left, right):
    """Multiply affine matrices using six row-major coefficients."""
    a,b,c,d,e,f = left
    g,h,i,j,k,l = right
    return (a*g+b*j, a*h+b*k, a*i+b*l+c,
            d*g+e*j, d*h+e*k, d*i+e*l+f)


def effective_affine(stabilization, mechanical, width, height, zoom):
    """Output pixel V, then mechanical M, finally ideal-source-ray S."""
    if not 1 <= zoom <= 2:
        raise ValueError("zoom outside implementation range")
    inv = 1/zoom
    viewport = (inv, 0, (width-1)*(1-inv)/2,
                0, inv, (height-1)*(1-inv)/2)
    return compose(stabilization, compose(mechanical, viewport))


def source_coordinate(matrix, u, v, lens):
    """Brown radial/tangential map, independently evaluated in float64."""
    a,b,c,d,e,f = matrix
    x,y = a*u+b*v+c, d*u+e*v+f
    k1,k2,p1,p2,fx,fy,cx,cy = lens
    r2 = x*x+y*y
    radial = 1+k1*r2+k2*r2*r2
    return (fx*(x*radial+2*p1*x*y+p2*(r2+2*x*x))+cx,
            fy*(y*radial+p1*(r2+2*y*y)+2*p2*x*y)+cy)


def verify_viewport(matrix, lens, width, height, *, margin=1/4096):
    """Check EVERY output centre and all four bilinear neighbours, not corners.

    A one-LSB margin protects Q12 source-coordinate quantization, but does not
    stand in for a measured complete fixed-point arithmetic error certificate.
    Return invalid pixel indices so remaining holes cannot be hidden by a flag.
    """
    invalid = []
    for v in range(height):
        for u in range(width):
            x,y = source_coordinate(matrix, u, v, lens)
            if not (margin <= x < width-1-margin and margin <= y < height-1-margin):
                invalid.append((u,v))
    return invalid


@dataclass(frozen=True)
class Observation:
    """An actual S1 source descriptor; derived results cannot become history."""
    epoch: int
    frame: int
    colour_version: int
    camera_version: int
    geometry_version: int
    registration_version: int
    mean_luma: float
    real_s1: bool = True
    legal: bool = True


def history_eligible(current, history, *, max_age, min_confidence, confidence,
                     max_luma_delta, slot_available, affine_enabled):
    """Conservative eligibility gate; capacity refusal never blocks capture."""
    if not affine_enabled or not slot_available or history is None:
        return False
    return (current.legal and history.legal and history.real_s1
            and current.epoch == history.epoch
            and 0 < current.frame-history.frame <= max_age
            and current.colour_version == history.colour_version
            and current.camera_version == history.camera_version
            and current.geometry_version == history.geometry_version
            and current.registration_version == history.registration_version
            and confidence >= min_confidence
            and abs(current.mean_luma-history.mean_luma) <= max_luma_delta)


def complete_pixel(current_rgb, current_valid, historical_rgb, historical_valid,
                   eligible, occluded):
    """Return RGB and provenance 0=invalid/1=current/2=history, never recursive."""
    if current_valid:
        return current_rgb, 1
    if eligible and historical_valid and not occluded:
        return historical_rgb, 2
    return (0,0,0), 0
