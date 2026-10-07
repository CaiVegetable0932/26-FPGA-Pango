"""Create an independent analytic full-raster fisheye validity reference.

Only simulation files are emitted; these maps are never loaded onto the board.
The narrow boundary band allows the documented fixed-point/LUT coordinate error.
"""
from pathlib import Path
import json
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from fisheye_geometry_reference import Lens, source_coordinate


def prepare(destination):
    """Classify every 1080p output pixel as valid, invalid or near the border."""
    destination.mkdir(parents=True, exist_ok=True)
    lens = Lens()
    words = lens.words()
    (destination / "fisheye_words.hex").write_text(
        "\n".join(f"{word & 0xffffffff:08x}" for word in words) + "\n", encoding="ascii")
    counts = [0, 0, 0]
    tolerance = .025
    with (destination / "fisheye_mask.hex").open("w", encoding="ascii") as stream:
        for y in range(lens.height):
            for x in range(lens.width):
                point = source_coordinate(words, 2, x, y)
                category = 0
                if point is not None:
                    u, v = point
                    margin = min(u, v, lens.width - 1 - u, lens.height - 1 - v)
                    category = 2 if abs(margin) <= tolerance else int(margin > 0)
                counts[category] += 1
                stream.write(f"{category:x}\n")
    result = dict(model="analytic_fisheye", counts=counts,
                  boundary_tolerance_px=tolerance, hardware_tested=False)
    (destination / "fisheye_reference.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))


if __name__ == "__main__":
    prepare(Path(sys.argv[1]))
