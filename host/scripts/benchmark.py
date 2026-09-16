"""In-memory decoder benchmark. Does not measure NIC, UDP socket, disk or FPGA."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from pango_video.cli import synthetic_pixels
from pango_video.protocol import packetize
from pango_video.reassembly import FrameAssembler

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=30)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--report", type=Path, default=ROOT / "reports/decoder-benchmark.json")
    args = parser.parse_args()
    if not 1 <= args.frames <= 120 or not 1 <= args.iterations <= 20:
        parser.error("frames must be 1..120 and iterations 1..20 (bounded prebuilt input)")
    prepared = [list(packetize(synthetic_pixels(2073600, f), stream_epoch=1, frame_id=f,
        width=1920, height=1080)) for f in range(args.frames)]
    runs = []
    for iteration in range(args.iterations):
        a = FrameAssembler(device_id="BENCHMARK-SYNTHETIC", stream_epoch=1)
        started = time.perf_counter()
        for frame_packets in prepared:
            for packet in frame_packets:
                frame = a.feed(packet)
        elapsed = time.perf_counter() - started
        runs.append(dict(elapsed_seconds=elapsed, packets_per_second=args.frames*1482/elapsed,
            complete_frames_per_second=a.stats["live_frames_complete"]/elapsed,
            complete_frames=a.stats["live_frames_complete"], assembly=a.status()))
    report = dict(utc=datetime.now(timezone.utc).isoformat(), python=sys.version,
        platform=platform.platform(), source_mode="synthetic_prebuilt_datagrams",
        hardware_acceptance="not_performed", frames_per_iteration=args.frames,
        input_resident_bytes=sum(map(len, (p for f in prepared for p in f))),
        excludes=["packet generation", "UDP sockets", "NIC", "disk", "GUI", "FPGA"],
        target_budget_packets_per_second=44460, runs=runs,
        source_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (ROOT/"src/pango_video").glob("*.py")})
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"report":str(args.report), "runs":runs}, indent=2))
    raise SystemExit(0 if all(r["complete_frames"] == args.frames for r in runs) else 2)
