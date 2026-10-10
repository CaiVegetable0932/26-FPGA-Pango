"""Run independent RGB calibration/reporting without starting or changing the Web UI."""
from pathlib import Path
import sys

# Resolve implementation from this checkout so a moved project remains usable.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from pango_video.offline_rgb_calibration import main

if __name__ == "__main__":
    raise SystemExit(main())
