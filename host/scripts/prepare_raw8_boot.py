"""Offline RAW8 commissioning metadata entry; does not touch physical devices."""
from pathlib import Path
import sys

# Purpose: use this checkout's host implementation without changing system paths.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from pango_video.raw8_boot import main

if __name__ == '__main__':
    main()
