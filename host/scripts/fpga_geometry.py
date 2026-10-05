"""Cross-platform, opt-in UART parameter uploader; never performs Flash writes."""
import argparse
import json
from pathlib import Path
import sys

# Purpose: keep the command runnable from a checkout without pip packaging.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"src"))
from pango_video.board_link import Uart
from pango_video.geometry_control import GeometryClient, GeometryProfile


def main():
    """Dry run is the default; only --port explicitly opens a real UART."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("preset", type=Path)
    parser.add_argument("--port", help="COM15 or /dev/ttyUSB0; omit for offline encoding")
    parser.add_argument("--rotation-deg", type=float, default=0)
    parser.add_argument("--version", type=int)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--no-enhance", action="store_true")
    args = parser.parse_args()
    preset = json.loads(args.preset.read_text(encoding="utf-8-sig"))
    profile = GeometryProfile.from_preset(preset, rotation_deg=args.rotation_deg, enhance=not args.no_enhance)
    result = dict(model=profile.model, width=profile.width, height=profile.height,
                  words=list(profile.words), parameters_origin=preset.get("parameters_origin", "unspecified"),
                  programmed=False, uploaded=False, hardware_image_verified=False)
    if args.port:
        link = Uart(args.port)
        try:
            result.update(GeometryClient(link).upload(profile, version=args.version, timeout=args.timeout), uploaded=True)
        finally:
            link.close()
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
