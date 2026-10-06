"""Compare NVIDIA forum capture methods on the uniquely verified Hagibis.

Retain direct V4L2/MJPEG and decoded RGB evidence. No driver, clocks, power
mode, system package or FPGA changes are made. Nonempty output is diagnostic
evidence, not proof of an intact HDMI frame or a verified source identity.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from check_hardware_inputs import HOST, linux_hagibis, write_json

SOURCES = {
    "v4l2": "https://forums.developer.nvidia.com/t/gstreamer-mjpg/331784/3",
    "software": "https://forums.developer.nvidia.com/t/set-camera-decoder-in-opencv-on-jetson-nano/177854/6",
    "parsed": "https://forums.developer.nvidia.com/t/opencv-camera-properties-cap-prop-fourcc-not-working/179520/15",
    "nvjpeg": "https://forums.developer.nvidia.com/t/opencv-camera-properties-cap-prop-fourcc-not-working/179520/15",
}


def main():
    """Run one bounded physical capture at a time; save full logs off terminal."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, choices=SOURCES)
    args = parser.parse_args()
    selected = linux_hagibis()
    run = "hagibis-forum-" + args.case + "-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    data, report_dir = HOST / "data" / run, HOST / "reports" / run
    data.mkdir()
    report_dir.mkdir()
    device = selected["device_path"]
    output = data / ("direct.mjpeg" if args.case == "v4l2" else "decoded.rgb")
    if args.case == "v4l2":
        # NVIDIA recommends direct v4l2-ctl to isolate GStreamer/plugin issues.
        command = [str(HOST / "build/environment/bin/v4l2-ctl"), "-d", device,
                   "--set-fmt-video=width=1280,height=720,pixelformat=MJPG",
                   "--set-parm=30", "--stream-mmap=4", "--stream-count=150",
                   "--stream-poll", "--stream-to=" + str(output), "--verbose"]
    else:
        # Use the forum's mmap/MJPEG pipeline and compare CPU decoding, JPEG
        # parsing, and NVIDIA's decoder. File output avoids display dependencies.
        command = ["gst-launch-1.0", "-e", "-v", "v4l2src", "device=" + device,
                   "io-mode=2", "num-buffers=600", "!",
                   "image/jpeg,width=1280,height=720,framerate=30/1", "!"]
        if args.case != "software":
            command += ["jpegparse", "!"]
        if args.case == "nvjpeg":
            command += ["nvjpegdec", "!", "video/x-raw(memory:NVMM),format=I420", "!",
                        "nvvidconv", "!", "video/x-raw,format=BGRx", "!"]
        else:
            command += ["jpegdec", "discard-corrupted-frames=true", "!"]
        command += ["videoconvert", "!", "video/x-raw,format=RGB,width=1280,height=720",
                    "!", "filesink", "location=" + str(output), "sync=false"]
    environment = dict(os.environ, GST_DEBUG="2", GST_DEBUG_NO_COLOR="1")
    report = dict(case=args.case, started_utc=datetime.now(timezone.utc).isoformat(),
                  source=SOURCES[args.case], selected_device=selected, command=command,
                  requested_size=[1280, 720], requested_fps=30,
                  source_frame_id=None, pairing_status="unverified", settings_changed=False)
    started = time.monotonic()
    # Bound stalled devices while preserving all diagnostic output and bytes.
    with (data / "stdout.log").open("wb") as stdout, (data / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, env=environment)
        try:
            report["returncode"] = process.wait(timeout=15)
            report["timed_out"] = False
        except subprocess.TimeoutExpired:
            process.kill()
            report["returncode"] = process.wait()
            report["timed_out"] = True
    report["elapsed_seconds"] = time.monotonic() - started
    report["output_bytes"] = output.stat().st_size if output.exists() else 0
    report["valid_capture_confirmed"] = False
    if report["output_bytes"]:
        raw = output.read_bytes()
        report["output_sha256"] = hashlib.sha256(raw).hexdigest()
        if args.case == "v4l2":
            report["jpeg_markers"] = {name: raw.count(marker) for name, marker in
                                      {"SOI": b"\xff\xd8", "EOI": b"\xff\xd9", "SOF0": b"\xff\xc0"}.items()}
        else:
            # Byte count is only a candidate frame count; corruption concealment
            # can also produce RGB. Preserve a first-frame preview for inspection.
            frame_bytes = 1280 * 720 * 3
            report["rgb_frame_sized_blocks"] = len(raw) // frame_bytes
            report["rgb_remainder_bytes"] = len(raw) % frame_bytes
            if len(raw) >= frame_bytes:
                (data / "first_frame.rgb").write_bytes(raw[:frame_bytes])
                result = subprocess.run([str(HOST / "build/environment/bin/ffmpeg"),
                    "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "rawvideo",
                    "-pixel_format", "rgb24", "-video_size", "1280x720", "-i",
                    str(data / "first_frame.rgb"), "-frames:v", "1", "-threads", "1",
                    str(data / "first_frame.png")], capture_output=True, timeout=15)
                report["preview_returncode"] = result.returncode
    report["data_dir"] = str(data)
    write_json(report_dir / "result.json", report)
    print(json.dumps({key: report.get(key) for key in ("case", "returncode", "timed_out",
                     "elapsed_seconds", "output_bytes", "jpeg_markers", "rgb_frame_sized_blocks",
                     "valid_capture_confirmed", "data_dir")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
