"""Launch two local processes, verify synthetic UDP frames and archived bytes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from pango_video.cli import synthetic_pixels

def check_case(frames, fps, seconds, drop_index=None):
    config = json.loads((ROOT/"config/receiver.mock.json").read_text(encoding="utf-8"))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rx_port, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as tx_port:
        rx_port.bind(("127.0.0.1", 0))
        tx_port.bind(("127.0.0.1", 0))
        config["port"] = rx_port.getsockname()[1]
        config["peer_port"] = tx_port.getsockname()[1]
    config_path = ROOT/"build"/("smoke-"+uuid.uuid4().hex[:8]+".json")
    config_path.write_text(json.dumps(config, indent=2)+"\n", encoding="utf-8")
    base = [sys.executable, "-X", "utf8", "-B", str(ROOT/"scripts/praw.py")]
    flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
    receiver = subprocess.Popen(base+["receive", "--config", str(config_path),
        "--seconds", str(seconds), "--archive-every", str(frames)], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", creationflags=flags)
    try:
        first = receiver.stdout.readline()
        if not first:
            raise RuntimeError("receiver failed to start: "+receiver.stderr.read())
        listening = json.loads(first)
        sender_args = base+["simulate", "--config", str(config_path), "--frames", str(frames), "--fps", str(fps)]
        if drop_index is not None:
            sender_args += ["--drop-index", str(drop_index)]
        sender = subprocess.run(sender_args, capture_output=True, text=True, encoding="utf-8",
                                timeout=20, creationflags=flags)
        stdout, stderr = receiver.communicate(timeout=20)
    finally:
        if receiver.poll() is None:
            receiver.terminate()
            receiver.communicate(timeout=5)
    finished = json.loads(stdout.strip().splitlines()[-1])
    report = json.loads(Path(finished["report"]).read_text(encoding="utf-8"))
    count = report["receiver"]["assembly"]["counters"].get("live_frames_complete", 0)
    expected = frames if drop_index is None else 0
    result = dict(source_mode="mock", config=str(config_path), run_id=listening["run_id"],
        receiver_report=finished["report"], sender_returncode=sender.returncode,
        receiver_returncode=receiver.returncode, sender_output=sender.stdout,
        receiver_stderr=stderr, sender_stderr=sender.stderr, expected_complete_frames=expected,
        actual_complete_frames=count, drop_index=drop_index)
    if drop_index is None and count:
        raw_files = list(Path(listening["data_directory"]).glob("*/image.raw"))
        result["archive_files"] = len(raw_files)
        result["first_frame_archive_matches"] = len(raw_files)==1 and raw_files[0].read_bytes()==synthetic_pixels(2073600, 0)
        result["first_frame_sha256"] = hashlib.sha256(synthetic_pixels(2073600, 0)).hexdigest()
    result["passed"] = (sender.returncode==0 and count==expected and
        receiver.returncode==(0 if drop_index is None else 2) and
        (drop_index is not None or result.get("first_frame_archive_matches", False)))
    return result

if __name__ == "__main__":
    cases = [check_case(30, 30, 5), check_case(2, 5, 2, drop_index=1)]
    report = dict(utc=datetime.now(timezone.utc).isoformat(), hardware_acceptance="not_performed",
        transport="two processes over IPv4 loopback", cases=cases, passed=all(c["passed"] for c in cases))
    output = ROOT/"reports/udp-smoke.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report["passed"] else 1)
