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
    raise SystemExit(main())
