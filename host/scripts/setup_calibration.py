"""Install the pinned calibration runtime locally, including on Ubuntu 24.04."""
from pathlib import Path
import os
import subprocess
import venv

if __name__ == "__main__":
    # A venv avoids modifying system Python and Ubuntu's managed packages.
    root = Path(__file__).resolve().parents[1]
    target = root / "build" / "calibration-venv"
    venv.EnvBuilder(with_pip=True).create(target)
    python = target / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(root / "requirements-calibration.txt")], check=True)
    subprocess.run([str(python), "-c", "import cv2,numpy; print('OpenCV',cv2.__version__,'NumPy',numpy.__version__)"], check=True)

