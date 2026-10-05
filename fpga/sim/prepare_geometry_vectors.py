"""Prepare deterministic analytic vectors under fpga/build, not references."""
import json
import math
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"model"))
from fisheye_geometry_reference import Lens, radial_scale, source_coordinate


def prepare(destination):
    """Export parameter/coordinate expectations, never hardware configuration LUTs."""
    destination.mkdir(parents=True, exist_ok=True)
    lens = Lens()
    words = lens.words()
    (destination/"parameters.hex").write_text("\n".join(f"{w & 0xffffffff:08x}" for w in words)+"\n", encoding="ascii")
    coefficients = [w/(1 << 26) for w in words[6:10]]
    lut = [round(radial_scale(2, i/32, coefficients)*(1 << 26)) for i in range(1025)]
    (destination/"expected_lut.hex").write_text("\n".join(f"{w:08x}" for w in lut)+"\n", encoding="ascii")
    randomizer = random.Random(20261004)
    points = [(0,0),(1919,1079),(960,540),(0,540),(1919,540)]
    points += [(randomizer.randrange(1920),randomizer.randrange(1080)) for _ in range(300)]
    rows = []
    for x,y in points:
        coordinate = source_coordinate(words,2,x,y)
        valid = coordinate is not None and 0 <= coordinate[0] <= 1919 and 0 <= coordinate[1] <= 1079
        u,v = coordinate or (0,0)
        rows.append(f"{x} {y} {int(valid)} {round(u*4096)} {round(v*4096)}\n")
    (destination/"coordinates.txt").write_text("".join(rows), encoding="ascii")
    (destination/"reference.json").write_text(json.dumps({"vector_count":len(rows),"parameters":words,
        "origin":"manual_approximate","hardware_acceptance":"not_performed"},indent=2),encoding="utf-8")
    # Purpose: exercise nonzero Brown radial/tangential terms and an explicit
    # in-plane rotation separately; these synthetic coefficients are NOT the
    # user's fish-eye calibration and must never be sent as its preset.
    brown = Lens(model=1, k1=.015, k2=.0004, k3=.004, k4=-.003,
                 output_fov_deg=80, rotation_deg=27)
    brown_words = brown.words()
    (destination/"brown_parameters.hex").write_text("\n".join(f"{w & 0xffffffff:08x}" for w in brown_words)+"\n", encoding="ascii")
    brown_lut = [round(radial_scale(1, i/32, [w/(1 << 26) for w in brown_words[6:10]])*(1 << 26)) for i in range(1025)]
    (destination/"brown_lut.hex").write_text("\n".join(f"{w:08x}" for w in brown_lut)+"\n", encoding="ascii")
    brown_rows = []
    for x,y in points:
        coordinate = source_coordinate(brown_words,1,x,y)
        valid = coordinate is not None and 0 <= coordinate[0] <= 1919 and 0 <= coordinate[1] <= 1079
        u,v = coordinate or (0,0)
        brown_rows.append(f"{x} {y} {int(valid)} {round(u*4096)} {round(v*4096)}\n")
    (destination/"brown_coordinates.txt").write_text("".join(brown_rows), encoding="ascii")
    # Interpolated radial table budget, separate from actual RTL comparison.
    errors=[]
    for _ in range(3000):
        x,y=randomizer.randrange(1920),randomizer.randrange(1080)
        a=[w/(1 << 26) for w in words[:6]]
        nx,ny=a[0]*x+a[1]*y+a[2],a[3]*x+a[4]*y+a[5]
        r2=nx*nx+ny*ny;index=int(r2*32);fraction=r2*32-index
        interp=((1-fraction)*lut[index]+fraction*lut[index+1])/(1 << 26)
        actual=radial_scale(2,r2,coefficients)
        errors.append(max(abs(nx*(interp-actual)*lens.fx),abs(ny*(interp-actual)*lens.fy)))
    maximum=max(errors)
    if maximum>.25: raise AssertionError(f"LUT coordinate error {maximum}")
    print(json.dumps({"reference_vectors":len(rows),"analytic_lut_max_coordinate_error_px":maximum}))


if __name__=="__main__":
    prepare(Path(sys.argv[1]).resolve())
