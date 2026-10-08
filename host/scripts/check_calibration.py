"""Run host software regression and record actual results, never hardware claims."""
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import platform
import subprocess
import sys
import unittest


def main():
    """Keep the report in host/reports and use the same OpenCV runtime as the UI."""
    # Windows consoles may default to GBK; Node status glyphs require UTF-8.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root / "src"))
    import cv2
    import numpy
    stream = io.StringIO()
    suite = unittest.defaultTestLoader.discover(str(root / "tests"))
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    js = subprocess.run(["node", "--test", *map(str, sorted((root / "tests").glob("*.cjs")))], capture_output=True, text=True, encoding="utf-8")
    syntax = subprocess.run(["node", "--check", str(root / "web/calibration.js")], capture_output=True, text=True, encoding="utf-8")
    report = dict(timestamp=datetime.now(timezone.utc).isoformat(), scope="synthetic_software_only",
                  platform=platform.platform(), python=sys.version, opencv=cv2.__version__, numpy=numpy.__version__,
                  python_tests=result.testsRun, python_passed=result.wasSuccessful(), python_output=stream.getvalue(),
                  javascript_exit=js.returncode, javascript_output=js.stdout + js.stderr,
                  calibration_js_syntax_exit=syntax.returncode, calibration_js_syntax_output=syntax.stdout + syntax.stderr,
                  hardware_validation="not_performed", ubuntu_validation="not_performed",
                  browser_visual_validation="not_performed_by_script")
    report_path = root / "reports/calibration-software-checks.json"
    report_path.parent.mkdir(exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(stream.getvalue())
    print(js.stdout, js.stderr)
    print("Report:", report_path)
    return 0 if result.wasSuccessful() and js.returncode == 0 and syntax.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
