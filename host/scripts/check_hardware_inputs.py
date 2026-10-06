"""Check the real Linux RAW8/HDMI inputs through the running local workbench.

Keep the receiver running, retain original RAW8 and MJPEG/RGB evidence, and
never infer HDMI source-frame identity or camera throughput from UVC settings.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import time

HOST = Path(__file__).resolve().parents[1]


def write_json(path, value):
    """Retain structured evidence without dumping image bytes to the terminal."""
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def api(route, data=None, port=8765):
    """Use only loopback and the server's normal session-token authorization."""
    headers = {}
    if data is not None:
        headers = {"Content-Type": "application/json", "X-Pango-Token": api("/api/session", port=port)["token"]}
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    try:
        connection.request("GET" if data is None else "POST", route,
                           None if data is None else json.dumps(data).encode(), headers)
        response = connection.getresponse()
        result = json.loads(response.read())
        if response.status >= 400:
            raise RuntimeError(str(result))
        return result
    finally:
        connection.close()


def linux_hagibis():
    """Require one capture node with verified USB IDs, name and physical path."""
    matches = []
    for path in sorted(Path("/dev/v4l/by-path").glob("*-video-index0")):
        result = subprocess.run(["udevadm", "info", "--query=property", "--name=" + str(path)],
                                capture_output=True, text=True, check=True, timeout=10)
        properties = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        if (properties.get("ID_VENDOR_ID"), properties.get("ID_MODEL_ID")) != ("1de1", "f105"):
            continue
        if properties.get("ID_MODEL") != "Hagibis" or ":capture:" not in properties.get("ID_V4L_CAPABILITIES", ""):
            raise RuntimeError("Hagibis identity/capture capability mismatch")
        matches.append(dict(device_path=str(path), resolved_path=str(path.resolve()), properties=properties))
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one physical Hagibis capture node; found {len(matches)}")
    return matches[0]


def command(args, folder, name, timeout=30):
    """Bound each capture subprocess and preserve diagnostics on failure."""
    try:
        result = subprocess.run([str(arg) for arg in args], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        # A stalled UVC read must still leave its negotiated format and driver
        # errors available for diagnosis. subprocess.run kills its own child.
        (folder / (name + ".stdout.log")).write_bytes(error.stdout or b"")
        (folder / (name + ".stderr.log")).write_bytes(error.stderr or b"")
        raise RuntimeError(f"{name} timed out after {timeout}s; see {folder}") from error
    (folder / (name + ".stdout.log")).write_bytes(result.stdout)
    (folder / (name + ".stderr.log")).write_bytes(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}); see {folder}")
    return result


def hdmi_capture(folder, size, seconds, fps=30, settle_seconds=0):
    """Preserve UVC MJPEG packets and decoded RGB without rescaling the input."""
    selected = linux_hagibis()
    write_json(folder / "device.json", selected)
    ffmpeg = HOST / "build/environment/bin/ffmpeg"
    probe = HOST / "build/environment/bin/ffprobe"
    width, height = map(int, size.split("x"))
    command([ffmpeg, "-hide_banner", "-nostdin", "-f", "v4l2", "-input_format", "mjpeg",
             "-framerate", fps, "-video_size", size, "-i", selected["device_path"],
             "-t", seconds, "-map", "0:v:0", "-an", "-c:v", "copy", folder / "capture.mkv"], folder, "capture")
    result = command([probe, "-v", "error", "-count_frames", "-show_streams", "-show_format",
                      "-of", "json", folder / "capture.mkv"], folder, "probe")
    stream = json.loads(result.stdout)
    # Preserve the entire compressed stream, including startup corruption.
    # An explicitly requested settling interval selects a later native frame
    # without resizing or concealing the original transport evidence.
    sample = "settled_frame" if settle_seconds else "first_frame"
    seek = ["-ss", str(settle_seconds)] if settle_seconds else []
    command([ffmpeg, "-hide_banner", "-nostdin", *seek, "-i", folder / "capture.mkv", "-frames:v", "1",
             "-an", "-pix_fmt", "rgb24", "-f", "rawvideo", folder / (sample + ".rgb")], folder, "rgb")
    raw = (folder / (sample + ".rgb")).read_bytes()
    actual = stream["streams"][0]
    if settle_seconds:
        frames = command([probe, "-v", "error", "-show_frames", "-show_entries",
                          "frame=width,height,best_effort_timestamp_time", "-of", "json",
                          folder / "capture.mkv"], folder, "frames")
        steady = [frame for frame in json.loads(frames.stdout)["frames"]
                  if float(frame.get("best_effort_timestamp_time", "0")) >= settle_seconds]
        geometry_ok = bool(steady) and all((frame["width"], frame["height"]) == (width, height) for frame in steady)
    else:
        geometry_ok = (actual["width"], actual["height"]) == (width, height)
    if not geometry_ok or len(raw) != width * height * 3:
        raise RuntimeError("Decoded capture geometry differs from requested format")
    command([ffmpeg, "-hide_banner", "-nostdin", "-f", "rawvideo", "-pixel_format", "rgb24",
             "-video_size", size, "-i", folder / (sample + ".rgb"), "-frames:v", "1",
             "-threads", "1", folder / (sample + ".png")], folder, "png")
    metadata = dict(status="captured_unverified", device=selected, requested_size=[width, height],
                    requested_capture_fps=fps, requested_seconds=seconds, probe=stream,
                    source_frame_id=None, pairing_status="unverified", fpga_video_verified=False,
                    audio_captured=False, capture_transport="MJPEG via Linux V4L2",
                    decoded_rgb_bytes=len(raw), decoded_rgb_sha256=hashlib.sha256(raw).hexdigest(),
                    sampled_frame=sample, settle_seconds=settle_seconds,
                    note="Inspect decoded image; a UVC frame can contain a capture-card No Signal pattern.")
    write_json(folder / "metadata.json", metadata)
    return metadata


def main():
    """Optionally start the saved physical profile; measure a bounded real window."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connect", action="store_true")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--hdmi-seconds", type=int, default=3)
    parser.add_argument("--settle-seconds", type=int, default=0,
                        help="preserve startup packets but inspect a later native frame")
    parser.add_argument("--size", choices=("1280x720", "1920x1080"), default="1280x720")
    parser.add_argument("--capture-fps", type=int, choices=(15, 30, 60), default=30)
    parser.add_argument("--hdmi-only", action="store_true")
    parser.add_argument("--network-only", action="store_true",
                        help="measure/save real RAW8 without competing with an open browser HDMI preview")
    parser.add_argument("--status-only", action="store_true",
                        help="read current board/network/device state without starting or stopping capture")
    parser.add_argument("--pause-network", action="store_true",
                        help="temporarily stop this workbench's UDP receiver, then restore the saved board link")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 120 or not 1 <= args.hdmi_seconds <= 10:
        parser.error("Use a 1–120 second network window and a 1–10 second HDMI capture")
    if not 0 <= args.settle_seconds < args.hdmi_seconds:
        parser.error("Settling interval must be shorter than HDMI recording")
    if args.network_only and (args.hdmi_only or args.pause_network):
        parser.error("network-only cannot be combined with HDMI-only or pausing the receiver")
    if args.status_only and (args.connect or args.pause_network or args.hdmi_only or args.network_only):
        parser.error("status-only cannot be combined with capture/start/stop actions")
    run = "hardware-inputs-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report_dir, data_dir = HOST / "reports" / run, HOST / "data" / run
    report_dir.mkdir()
    data_dir.mkdir()
    report = dict(started_utc=datetime.now(timezone.utc).isoformat(), run_id=run,
                  camera_source_verified=False, hdmi_pairing_status="unverified")
    restore = None
    try:
        if args.status_only:
            report["board"] = api("/api/board/status", port=args.port)
            report["network_status"] = api("/api/status", port=args.port)
            report["selected_hdmi_device"] = linux_hagibis()
            current = report["network_status"]
            print(json.dumps(dict(event="CURRENT", board_phase=report["board"]["phase"],
                                  network_signal=current["signal"], complete_fps=current["complete_fps"],
                                  saved_frames=current["saved_frames"],
                                  hdmi_path=report["selected_hdmi_device"]["device_path"])), flush=True)
            return 0
        if args.pause_network:
            current = api("/api/status", port=args.port)
            if current["running"]:
                if current["config"]["source_mode"] != "hardware_unverified":
                    raise RuntimeError("Refuse to stop an unrelated mock session")
                restore = api("/api/board/status", port=args.port)["profile"]
                api("/api/board/stop", {}, args.port)
        if args.hdmi_only:
            report["hdmi"] = hdmi_capture(data_dir, args.size, args.hdmi_seconds, args.capture_fps, args.settle_seconds)
            report["hdmi_data_dir"] = str(data_dir.relative_to(HOST))
            return 0
        if args.connect:
            profile = json.loads((HOST / "config/board-link.json").read_text(encoding="utf-8"))
            report["startup"] = api("/api/board/start", profile, args.port)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            board = api("/api/board/status", port=args.port)
            if not board["busy"]:
                break
            time.sleep(.5)
        report["board"] = board
        print(json.dumps(dict(event="BOARD", status=board), ensure_ascii=False), flush=True)
        before = api("/api/status", port=args.port)
        if before["config"]["source_mode"] != "hardware_unverified":
            raise RuntimeError("Refuse to treat mock images as hardware input")
        started = time.monotonic()
        samples = []
        while time.monotonic() - started < args.seconds:
            status = api("/api/status", port=args.port)
            samples.append(dict(elapsed=time.monotonic() - started, signal=status["signal"],
                                complete_fps=status["complete_fps"], payload_mb_s=status["payload_mb_s"],
                                metrics=status["metrics"]))
            if len(samples) % 5 == 0:
                print(json.dumps(dict(event="NETWORK", **{key: samples[-1][key] for key in
                                                          ("elapsed", "signal", "complete_fps", "payload_mb_s")})), flush=True)
            time.sleep(1)
        after = api("/api/status", port=args.port)
        elapsed = time.monotonic() - started
        first_counts = before.get("metrics", {}).get("assembly", {}).get("counters", {})
        last_counts = after.get("metrics", {}).get("assembly", {}).get("counters", {})
        delta = {key: value - first_counts.get(key, 0) for key, value in last_counts.items()}
        complete = delta.get("live_frames_complete", 0)
        report["network"] = dict(before=before, after=after, samples=samples,
                                  measured_seconds=elapsed, assembly_counter_delta=delta,
                                  complete_fps_in_window=complete / elapsed,
                                  complete_frames_received=complete, image_transport_passed=complete >= 3)
        if after["signal"] == "live":
            report["raw_save"] = api("/api/save", {}, args.port)
            time.sleep(1)
            report["raw_run_id"] = after["run_id"]
        # The browser retains its real Hagibis track during reboot/network
        # checks. Do not open V4L2 simultaneously or interrupt that preview.
        if args.network_only:
            report["hdmi_test_skipped"] = "Existing browser preview retains capture ownership"
            return 0 if report["network"]["image_transport_passed"] else 2
        # UART and the UDP receiver remain owned by the running Web workbench.
        # The native capture is released before the user opens browser preview.
        report["hdmi"] = hdmi_capture(data_dir, args.size, args.hdmi_seconds, args.capture_fps, args.settle_seconds)
        report["hdmi_data_dir"] = str(data_dir.relative_to(HOST))
    except Exception as error:
        report["error"] = str(error)
        print(str(error), flush=True)
    finally:
        # A capture-only diagnostic must not leave a previously running user's
        # board preview stopped, even when USB capture raises an error.
        if restore:
            try:
                report["network_restored"] = api("/api/board/start", restore, args.port)
            except Exception as error:
                report["restore_error"] = str(error)
        write_json(report_dir / "inputs.json", report)
        print(json.dumps(dict(report=str(report_dir / "inputs.json"), data=str(data_dir))), flush=True)
    return 0 if not report.get("error") and report.get("network", {}).get("image_transport_passed") else 2


if __name__ == "__main__":
    raise SystemExit(main())
