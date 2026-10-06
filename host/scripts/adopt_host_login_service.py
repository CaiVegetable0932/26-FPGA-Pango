"""Transfer this checkout's manual server to the persisted desktop user service.

Validate the exact process and loopback instance before a graceful SIGTERM.
Never terminate browsers, other checkouts, or an unrelated process using 8765.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from check_hardware_inputs import HOST, api, write_json


def main():
    """Exercise login startup while preserving existing saved board/session settings."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pid", type=int)
    mode.add_argument("--status-only", action="store_true", help="record the running login service without restarting it")
    args = parser.parse_args()
    if args.status_only:
        # A delayed first startup can exceed the adoption monitor while still
        # succeeding. Recheck the actual stable service without another restart.
        status, board = api("/api/status"), api("/api/board/status")
        state = subprocess.check_output(["systemctl", "--user", "show", "pango-host",
                                         "-p", "ActiveState", "-p", "MainPID"], text=True)
        passed = status["signal"] == "live" and board["phase"] == "ready" and "ActiveState=active" in state
        path = HOST / "reports/hardware_inputs_20261003" / ("login-service-status-" + datetime.now(timezone.utc).strftime("%H%M%S%f") + ".json")
        write_json(path, dict(utc=datetime.now(timezone.utc).isoformat(), passed=passed,
                             status=status, board=board, service=state, settings_changed=False))
        print(json.dumps(dict(report=str(path), passed=passed, service=state)), flush=True)
        if not passed:
            raise RuntimeError("Login service is not yet providing ready/live hardware input")
        return
    process = Path("/proc") / str(args.pid)
    command = (process / "cmdline").read_bytes().split(b"\0")
    wanted = str(HOST / "scripts/web.py").encode()
    if wanted not in command or os.stat(process).st_uid != os.getuid():
        raise RuntimeError("PID does not belong to this user's exact workbench")
    if api("/api/status")["config"]["source_mode"] != "hardware_unverified":
        raise RuntimeError("Refuse to stop an unrelated/mock session")
    report = dict(started_utc=datetime.now(timezone.utc).isoformat(), previous_pid=args.pid,
                  previous_status=api("/api/status"), previous_board=api("/api/board/status"))
    print("Gracefully handing the receiver to pango-host.service.", flush=True)
    os.kill(args.pid, signal.SIGTERM)
    deadline = time.monotonic() + 35
    while process.exists() and time.monotonic() < deadline:
        time.sleep(.25)
    if process.exists():
        raise RuntimeError("Manual server did not exit gracefully; no forced termination")
    subprocess.run(["systemctl", "--user", "start", "pango-host.service"], check=True, timeout=60)
    deadline = time.monotonic() + 65
    while time.monotonic() < deadline:
        try:
            status = api("/api/status")
            board = api("/api/board/status")
            if status["signal"] == "live" and board["phase"] == "ready":
                break
        except (OSError, ValueError, RuntimeError):
            pass
        time.sleep(1)
    else:
        raise RuntimeError("Persisted service started but board/live input did not become ready")
    report.update(current_status=status, current_board=board,
                  service=subprocess.check_output(["systemctl", "--user", "show", "pango-host",
                                                   "-p", "ActiveState", "-p", "MainPID"], text=True),
                  passed=True, finished_utc=datetime.now(timezone.utc).isoformat())
    folder = HOST / "reports/hardware_inputs_20261003"
    path = folder / ("login-service-adoption-" + datetime.now(timezone.utc).strftime("%H%M%S%f") + ".json")
    write_json(path, report)
    print(json.dumps(dict(report=str(path), passed=True, signal=status["signal"],
                          board_phase=board["phase"], service=report["service"])), flush=True)


if __name__ == "__main__":
    main()
