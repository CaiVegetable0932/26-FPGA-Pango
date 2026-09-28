"""Purpose: check the geometry reference against floating-point calibration math."""

import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from geometry_reference import CameraGeometry, inverse_fixed, sample_rgb


def main() -> None:
    """Check realistic calibrated coordinates, zero-distortion identity and RGB rounding."""
    camera = CameraGeometry(1300, 1290, 960, 540, 1300, 1290, 960, 540,
                            -0.13, 0.02, 0.001, -0.0008)
    rng = random.Random(5640)
    worst = 0.0
    for angle in (0, 1, 30, 45, 89, 135, 270, 359):
        words = camera.fixed_words(angle)
        for _ in range(300):
            u,v = rng.randrange(1920),rng.randrange(1080)
            actual = inverse_fixed(words,u,v)
            expected = camera.inverse_float(u,v,angle)
            error = math.hypot(actual[0]/4096-expected[0],actual[1]/4096-expected[1])
            worst = max(worst,error)
            assert error < 0.05, (angle,u,v,error)
    identity = CameraGeometry(256,256,0,0,256,256,0,0)
    assert inverse_fixed(identity.fixed_words(),7,5) == (7*4096,5*4096)
    assert sample_rgb((0,0,0),(255,0,0),(0,255,0),(0,0,255),2048,2048) == (64,64,64)
    print(f"GEOMETRY_REFERENCE_PASS worst_coordinate_error={worst:.6f}px")


if __name__ == "__main__":
    main()
