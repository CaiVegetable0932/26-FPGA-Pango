"""Portable unittest runner; reports stay under host/reports."""
import argparse
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import platform
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=ROOT / "reports/protocol-tests.json")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), pattern="test_*.py")
    stream = io.StringIO()
    started = time.perf_counter()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    elapsed = time.perf_counter() - started
    print(stream.getvalue())
    report = dict(utc=datetime.now(timezone.utc).isoformat(), python=sys.version,
        platform=platform.platform(), tests_run=result.testsRun, failures=len(result.failures),
        errors=len(result.errors), skipped=len(result.skipped), passed=result.wasSuccessful(),
        elapsed_seconds=elapsed, hardware_acceptance="not_performed", output=stream.getvalue())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
