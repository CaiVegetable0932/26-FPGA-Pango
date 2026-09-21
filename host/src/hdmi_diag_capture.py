"""Short, video-only Hagibis HDMI diagnostic capture; never asserts FPGA frame identity.

Uses a project-local pinned imageio-ffmpeg binary. Stream-copied MJPEG is retained;
RGB/PNG/MP4 are decoded/visual derivatives, not raw FPGA samples or precision evidence.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

HOST = Path(__file__).resolve().parents[1]
DEVICE = "Hagibis"


def verified_device(folder: Path) -> dict:
    """Enumerate immediately before open; reject webcam/ambiguous USB identities."""
    evidence = folder / "device_enumeration.json"
    subprocess.run(["powershell.exe", "-NoProfile", "-File",
                    str(HOST / "scripts/enumerate_hagibis.ps1"),
                    "-OutputPath", str(evidence)], check=True, capture_output=True,
                   timeout=20, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    devices = json.loads(evidence.read_text(encoding="utf-8-sig"))
    matches = devices.get("hagibis_matches", [])
    if not devices.get("unique_hagibis") or len(matches) != 1:
        raise RuntimeError("Expected one Hagibis capture device")
    selected = matches[0]
    if selected.get("FriendlyName") != DEVICE or "vid_1de1&pid_f105" not in selected.get("MonikerDisplayName", "").lower():
        raise RuntimeError("Capture identity is not the expected Hagibis USB device")
    return selected

def run(ffmpeg: Path, args: list[str], folder: Path, name: str, timeout: int = 30):
    """Run without a shell/window, retain logs, and terminate only this process on timeout."""
    command = [str(ffmpeg), "-hide_banner", "-nostdin", *args]
    result = subprocess.run(command, capture_output=True, timeout=timeout,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    (folder / (name + ".stdout.log")).write_bytes(result.stdout)
    (folder / (name + ".stderr.log")).write_bytes(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}); see retained logs")
    return result

def capture(seconds: int = 2) -> Path:
    """Capture the explicitly reviewed external device only, with audio disabled."""
    if not 1 <= seconds <= 10:
        raise ValueError("Diagnostic capture must be between 1 and 10 seconds")
    ffmpeg = HOST / "build/capture_runtime/imageio_ffmpeg/binaries/ffmpeg-win-x86_64-v7.1.exe"
    if not ffmpeg.is_file():
        raise RuntimeError("Install imageio-ffmpeg==0.6.0 into host/build/capture_runtime first")
    folder = HOST / "data" / ("hdmi_diag_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
    folder.mkdir(parents=True, exist_ok=False)
    meta = dict(device=DEVICE, requested_size=[1280, 720], requested_capture_fps=30,
                requested_seconds=seconds, source_frame_id=None, pairing_status="unverified",
                fpga_video_verified=False, sensor_fps_measured=None, source_format="unknown",
                capture_transport="MJPEG via DirectShow", lossless_fpga_capture=False,
                audio_captured=False, started_utc=datetime.now(timezone.utc).isoformat(),
                ffmpeg_sha256=hashlib.sha256(ffmpeg.read_bytes()).hexdigest(), status="running")
    started = time.monotonic()
    try:
        selected = verified_device(folder)
        # FFmpeg's DirectShow alternative name escapes moniker colons as '_'.
        # Bind the physical path, not a guessed numeric index or friendly name.
        device_path = selected["MonikerDisplayName"].replace(":", "_")
        meta["selected_device"] = selected
        # Preserve the original compressed packets and device timestamps in Matroska.
        run(ffmpeg, ["-f", "dshow", "-rtbufsize", "128M", "-vcodec", "mjpeg",
             "-framerate", "30", "-video_size", "1280x720", "-i", "video=" + device_path,
             "-t", str(seconds), "-map", "0:v:0", "-an", "-c:v", "copy",
             "-progress", "pipe:1", str(folder / "capture.mkv")], folder, "capture")
        # Retain a decoded RGB plane for inspection; it is not sensor-raw data.
        run(ffmpeg, ["-i", str(folder / "capture.mkv"), "-frames:v", "1",
             "-an", "-pix_fmt", "rgb24", "-f", "rawvideo", str(folder / "first_frame.rgb")],
             folder, "rgb")
        size = (folder / "first_frame.rgb").stat().st_size
        if size != 1280 * 720 * 3:
            raise RuntimeError(f"Unexpected decoded frame size {size}; do not assume 720p")
        run(ffmpeg, ["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "1280x720",
             "-i", str(folder / "first_frame.rgb"), "-frames:v", "1",
             str(folder / "first_frame.png")], folder, "png")
        run(ffmpeg, ["-i", str(folder / "capture.mkv"), "-an", "-c:v", "libx264",
             "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
             str(folder / "preview.mp4")], folder, "preview")
        meta.update(status="captured_unverified", decoded_format="RGB24",
                    decoded_frame_bytes=size)
    except Exception as exc:
        meta.update(status="failed", error=str(exc))
        raise
    finally:
        meta["wall_seconds"] = time.monotonic() - started
        meta["files"] = {p.name: {"bytes": p.stat().st_size,
                        "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                        for p in folder.iterdir() if p.is_file()}
        (folder / "metadata.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
        print(folder)
    return folder

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=2)
    capture(parser.parse_args().seconds)
