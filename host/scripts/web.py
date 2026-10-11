"""Portable entry point for the local Web workbench (standard library only)."""
from pathlib import Path
import sys

sys.dont_write_bytecode = True
if sys.version_info[:2] < (3, 12):
    print("[Pango] Python 3.12 or newer is required.", file=sys.stderr)
    raise SystemExit(2)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from pango_video.web_launcher import main

if __name__ == "__main__":
    # The UDP owner and preview/status HTTP threads share this interpreter.
    # Yield Python work every millisecond so a display request cannot repeatedly
    # stall socket draining for the default five-millisecond GIL interval.
    # This is local to the service process, not a Jetson power/driver setting.
    sys.setswitchinterval(min(sys.getswitchinterval(), 0.001))
    raise SystemExit(main())
