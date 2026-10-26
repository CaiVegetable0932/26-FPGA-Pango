"""Exercise physical Ethernet through the Web API; retain metrics, not video."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from pango_video.web_server import LocalServer
from pango_video.ethernet import expected_test_pixels


def main():
    """Explicit hardware opt-in; bounded receive and unconditional session cleanup."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hardware", action="store_true", required=True)
    parser.add_argument("--seconds", type=float, default=10)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error("seconds must be between 1 and 60")
    server = LocalServer(0)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    report = dict(started=datetime.now(timezone.utc).isoformat(), source="FPGA TEST, NOT CAMERA",
                  payloads_saved=False, network_settings_changed=False, board_reconfigured=False,
                  sampled_frames=0, exact_test_frames=0, frame_hashes=[], frontend_checks=[])

    def call(path, data=None):
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=8)
        try:
            connection.request("GET" if data is None else "POST", path,
                None if data is None else json.dumps(data),
                {} if data is None else {"Content-Type": "application/json", "X-Pango-Token": server.token})
            response = connection.getresponse()
            body = response.read()
            if response.status >= 400:
                raise ValueError(body.decode())
            return response.status, dict(response.getheaders()), body
        finally:
            connection.close()

    try:
        profile = json.loads(call("/api/ethernet/profile")[2])
        endpoints = {key: profile[key] for key in ("bind_ip", "port", "peer_ip", "peer_port")}
        discovery = json.loads(call("/api/ethernet/probe", endpoints)[2])
        report["discovery"] = discovery
        if discovery["source_stage"] != "TEST":
            raise ValueError("This checker compares only the explicit FPGA TEST source")
        call("/api/start", dict(archive_every=0, auto_mock=False))
        deadline = time.monotonic() + args.seconds
        last = ""
        while time.monotonic() < deadline:
            code, headers, body = call("/api/frame")
            if code == 200:
                meta = json.loads(headers["X-Frame-Info"])
                if meta["key"] != last:
                    last = meta["key"]
                    report["sampled_frames"] += 1
                    expected = expected_test_pixels(int(meta["frame_id"]), meta["width"], meta["height"])
                    if body != expected or meta["source_stage"] != "TEST" or not meta["synthetic"]:
                        raise ValueError("HTTP frame pixels/TEST identity mismatch")
                    report["exact_test_frames"] += 1
                    report["frame_hashes"].append(dict(frame_id=meta["frame_id"], sha256=hashlib.sha256(body).hexdigest()))
                    if len(report["frontend_checks"]) < 2:
                        # Execute the exact browser worker's pure pixel converter on real received bytes.
                        js = "const fs=require('fs'),crypto=require('crypto');const {renderPixels}=require(process.argv[1]);const b=fs.readFileSync(0);const m=JSON.parse(process.argv[2]);const r=renderPixels(b,m,'gray');const p=Buffer.from(r.pixels);if(r.width!==960||r.height!==540)process.exit(2);console.log(JSON.stringify({width:r.width,height:r.height,sha256:crypto.createHash('sha256').update(p).digest('hex')}));"
                        result = subprocess.run(["node", "-e", js, str(ROOT / "web/pixels.js"), json.dumps(meta)], input=body, capture_output=True, check=True)
                        report["frontend_checks"].append(json.loads(result.stdout))
            time.sleep(.125)
        report["final_status"] = json.loads(call("/api/stop", {})[2])
        report["passed"] = report["exact_test_frames"] >= 3 and bool(report["frontend_checks"])
    except Exception as error:
        report.update(passed=False, error=str(error))
    finally:
        report.setdefault("final_status", server.session.stop())
        server.shutdown(); server.server_close(); worker.join()
    report["note"] = "HTTP and pixel-converter integration; not browser FPS, camera/HDMI or lossless-stream acceptance."
    path = ROOT / "reports" / ("ethernet-preview-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(dict(passed=report["passed"], sampled_frames=report["sampled_frames"], report=str(path)), ensure_ascii=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
