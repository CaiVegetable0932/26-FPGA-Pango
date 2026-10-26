"""Measure saved 720p RGB24 evidence without modifying pixels or opening devices."""
import argparse
import hashlib
import json
from pathlib import Path


def measure(path: Path) -> dict:
    """Quantify decoded brightness only; not sensor exposure, lux or frame identity."""
    data = path.read_bytes()
    pixels = 1280 * 720
    if len(data) != pixels * 3:
        raise ValueError("Expected 1280x720 RGB24")
    total = dark = 0
    # Integer Rec.709-style luma approximation in the decoded 8-bit RGB domain.
    for r, g, b in zip(data[0::3], data[1::3], data[2::3]):
        luma = (54 * r + 183 * g + 19 * b) / 256
        total += luma
        dark += luma < 16
    return dict(path=str(path.resolve()), sha256=hashlib.sha256(data).hexdigest(),
                size=[1280, 720], mean_luma_8bit=total / pixels,
                fraction_luma_below_16=dark / pixels,
                measurement="decoded RGB brightness, not calibrated photometry",
                source_frame_id=None)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rgb", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    evidence = [measure(path) for path in args.rgb]
    # Preserve prior measurements; create a new evidence artifact, never overwrite.
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(evidence, handle, ensure_ascii=False, indent=2)
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
