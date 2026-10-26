"""Decode saved HDMI diagnostic recordings without opening any capture device.

Keep rejected samples and never label generated diagnostics as camera imagery.
The sampled timeline is the PC recording timeline, not FPGA frame identity.
"""
import argparse
import json
from pathlib import Path
import subprocess

from decode_dvp_diagnostic import decode


def inspect(recording: Path, output: Path) -> dict:
    """Sample up to ten seconds at 1 Hz; retain rejected frames instead of guessing geometry."""
    host = Path(__file__).resolve().parents[1]
    ffmpeg = host / "build/capture_runtime/imageio_ffmpeg/binaries/ffmpeg-win-x86_64-v7.1.exe"
    result = subprocess.run(
        [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-i", str(recording),
         "-t", "10", "-vf", "fps=1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"],
        check=True, capture_output=True, timeout=30,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    frame_bytes = 1280 * 720 * 3
    # No scaling is applied: geometry/header/cell checks reject incompatible data.
    if len(result.stdout) % frame_bytes:
        raise ValueError("Decoded stream is not an integral number of 720p RGB24 frames")
    samples = []
    for start in range(0, len(result.stdout), frame_bytes):
        item = {"sample_index": start // frame_bytes}
        try:
            item.update(status="decoded", diagnostic=decode(result.stdout[start:start + frame_bytes]))
        except ValueError as exc:
            item.update(status="rejected", error=str(exc))
        samples.append(item)
    evidence = dict(recording=str(recording.resolve()), samples=samples,
                    ffmpeg_stderr=result.stderr.decode("utf-8", errors="replace"),
                    camera_image_verified=False, source_frame_id=None,
                    sampling="PC recording at 1 Hz; not sensor FPS")
    # Purpose: generated analysis belongs beside retained host capture evidence.
    with output.open("x", encoding="utf-8") as handle:
        json.dump(evidence, handle, ensure_ascii=False, indent=2)
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.recording, args.output), ensure_ascii=False, indent=2))
