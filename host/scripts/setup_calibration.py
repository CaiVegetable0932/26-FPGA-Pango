"""Install pinned calibration dependencies without changing system Python."""
from pathlib import Path
import os
import subprocess
import sys
import venv

def calibration_python(root: Path) -> Path:
    """Reuse Jetson's launcher environment; otherwise create a local venv.

    Installing into a separate venv on Jetson would leave start_web.sh without
    OpenCV because that launcher prefers the prepared environment.
    """
    executable = "Scripts/python.exe" if os.name == "nt" else "bin/python"
    prepared = root / "build" / "environment" / "venv" / executable
    if os.name != "nt" and prepared.is_file():
        return prepared
    target = root / "build" / "calibration-venv"
    # Python 3.13+ accepts scm_ignore_files; its empty default preserves the
    # repository's no-extra-ignore policy. Python 3.12 has no ignore generation.
    venv.EnvBuilder(with_pip=True).create(target)
    return target / executable


def main() -> None:
    """Install into the project runtime and verify native extension imports."""
    if sys.version_info < (3, 12):
        raise SystemExit("Python 3.12 or newer is required; use the project runtime.")
    root = Path(__file__).resolve().parents[1]
    python = calibration_python(root)
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(root / "requirements-calibration.txt")], check=True)
    # The same interpreter must provide serial commissioning and calibration.
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(root / "requirements-device.txt")], check=True)
    subprocess.run([str(python), "-c", "import cv2,numpy; print('OpenCV',cv2.__version__,'NumPy',numpy.__version__)"], check=True)


if __name__ == "__main__":
    main()
