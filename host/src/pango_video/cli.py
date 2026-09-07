"""Headless receive and local synthetic sender; the GUI can reuse the same core."""

import argparse
from datetime import datetime, timezone
import ipaddress
import json
import math
from pathlib import Path
import socket
import sys
import threading
import time
import uuid

from .protocol import FormatLimits, packetize
from .reassembly import AssemblyLimits, FrameAssembler
from .receiver import UDPReceiver
from .storage import save_frame


HOST_ROOT = Path(__file__).resolve().parents[2]


def synthetic_pixels(size: int, frame_id: int) -> bytes:
    """Explicit test pattern, not camera evidence."""
    block = bytes((index * 13 + frame_id) & 255 for index in range(256))
    return (block * ((size + 255) // 256))[:size]


def load_config(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    return validate_config(data)


def validate_config(data: dict) -> dict:
    if not isinstance(data, dict):
        raise ValueError("configuration must be an object")
    required = {"device_id", "source_mode", "bind_ip", "port", "peer_ip", "peer_port",
                "stream_epoch", "width", "height", "bayer_code", "receive_buffer_bytes"}
    if set(data) != required:
        raise ValueError(f"configuration fields differ: {set(data) ^ required}")
    if data["source_mode"] not in ("mock", "hardware_unverified"):
        raise ValueError("invalid source mode")
    if not isinstance(data["device_id"], str) or not data["device_id"]:
        raise ValueError("fill in the confirmed device_id")
    for key in ("port", "peer_port", "stream_epoch", "width", "height", "bayer_code", "receive_buffer_bytes"):
        if type(data[key]) is not int:
            raise ValueError(f"fill in integer configuration field: {key}")
    if not 0 <= data["stream_epoch"] < 2**64 or data["bayer_code"] not in (1, 2, 3, 4):
        raise ValueError("invalid epoch or Bayer code")
    ipaddress.IPv4Address(data["bind_ip"])
    ipaddress.IPv4Address(data["peer_ip"])
    FormatLimits(data["width"], data["height"])
    return data


def receive(args, config: dict) -> int:
    run_id = f"{config['source_mode']}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}"
    output = HOST_ROOT / "data" / run_id
    report_path = HOST_ROOT / "reports" / run_id / "receiver.json"
    assembler = FrameAssembler(device_id=config["device_id"], stream_epoch=config["stream_epoch"],
                               format_limits=FormatLimits(config["width"], config["height"],
                                                          expected_bayer_code=config["bayer_code"]),
                               limits=AssemblyLimits())
    receiver = UDPReceiver(assembler, bind=(config["bind_ip"], config["port"]),
                           peer=(config["peer_ip"], config["peer_port"]),
                           receive_buffer_bytes=config["receive_buffer_bytes"], archive_every=args.archive_every)
    stop, writer_done = threading.Event(), threading.Event()
    writer_result = {"frames_saved": 0, "error": None}

    def writer():
        try:
            while not writer_done.is_set() or receiver.archive_frames.status()["frames"]:
                frame = receiver.archive_frames.get(timeout=0.05)
                if frame is None:
                    continue
                h = frame.header
                name = f"e{h.stream_epoch}_f{h.frame_id}_t{h.packet_type}_d{h.descriptor_id}"
                save_frame(frame, output / name, device_id=config["device_id"], source_mode=config["source_mode"])
                writer_result["frames_saved"] += 1
        except Exception as error:
            writer_result["error"] = repr(error)
            stop.set()

    bound = receiver.open()
    worker = threading.Thread(target=writer, name="praw-archive")
    worker.start()
    print(json.dumps({"event": "listening", "run_id": run_id, "bound": bound,
                      "peer": receiver.peer, "source_mode": config["source_mode"],
                      "data_directory": str(output)}, ensure_ascii=False), flush=True)
    started = time.monotonic()
    receive_error = None
    try:
        receiver.run(stop, duration=args.seconds or None)
    except KeyboardInterrupt:
        stop.set()
    except OSError as error:
        receive_error = repr(error)
    finally:
        elapsed = time.monotonic() - started
        receiver.close()
        writer_done.set()
        worker.join()
    status = receiver.status()
    complete = assembler.stats["live_frames_complete"]
    report = {"run_id": run_id, "configuration": config, "source_mode": config["source_mode"],
              "hardware_acceptance": "not_performed", "elapsed_receive_seconds": elapsed,
              "complete_live_fps_in_receive_window": complete / elapsed,
              "receiver": status, "storage": writer_result, "receive_error": receive_error,
              "notes": "No GUI consumer: preview replacements are expected. Host receive time is not FPGA latency."}
    report_path.parent.mkdir(parents=True, exist_ok=False)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"event": "finished", "report": str(report_path), "complete_frames": complete,
                      "frames_saved": writer_result["frames_saved"]}, ensure_ascii=False), flush=True)
    bad = (receive_error or writer_result["error"] or receiver.stats["archive_frames_rejected"]
           or status["assembly"]["live_unobserved_ids_in_span"]
           or not complete or any(v for k, v in assembler.stats.items()
                                   if k.startswith(("packets_rejected_", "frames_failed_", "frames_rejected_"))))
    return 2 if bad else 0


def simulate(args, config: dict) -> int:
    if config["source_mode"] != "mock" or not all(ipaddress.IPv4Address(config[k]).is_loopback
                                                   for k in ("bind_ip", "peer_ip")):
        raise ValueError("the synthetic sender only uses an explicit loopback mock configuration")
    count = (config["width"] * config["height"] + 1399) // 1400
    if args.drop_index is not None and args.drop_index >= count:
        raise ValueError("drop-index lies outside the frame")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
        sender.bind((config["peer_ip"], config["peer_port"]))
        started = time.monotonic()
        packets_sent = 0
        for frame_id in range(args.frames):
            data = synthetic_pixels(config["width"] * config["height"], frame_id)
            packets = list(packetize(data, stream_epoch=config["stream_epoch"], frame_id=frame_id,
                                     width=config["width"], height=config["height"],
                                     bayer_code=config["bayer_code"], descriptor_id=1))
            for index, packet in enumerate(packets):
                # Spread each frame through its period instead of dumping a full
                # 2 MB burst. OS scheduler granularity still needs measurement.
                target = started + (frame_id + index / len(packets)) / args.fps
                remaining = target - time.monotonic()
                if remaining > 0:
                    time.sleep(remaining)
                if args.drop_index is not None and index == args.drop_index:
                    continue
                sender.sendto(packet, (config["bind_ip"], config["port"]))
                packets_sent += 1
        elapsed = time.monotonic() - started
    print(json.dumps({"source_mode": "mock", "frames_generated": args.frames,
                      "datagrams_sent": packets_sent, "elapsed_seconds": elapsed,
                      "requested_fps": args.fps, "hardware_acceptance": "not_performed"}), flush=True)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="PRAW V1 UDP host core (no third-party dependencies)")
    commands = parser.add_subparsers(dest="command", required=True)
    rx = commands.add_parser("receive", help="receive, validate, reassemble and optionally archive RAW8")
    tx = commands.add_parser("simulate", help="send explicitly synthetic loopback RAW8 frames")
    for command in (rx, tx):
        command.add_argument("--config", type=Path, default=HOST_ROOT / "config" / "receiver.mock.json")
    rx.add_argument("--seconds", type=float, default=0, help="0 runs until Ctrl+C")
    rx.add_argument("--archive-every", type=int, default=0, help="0 counts only; N archives first and every Nth complete frame")
    tx.add_argument("--frames", type=int, default=30)
    tx.add_argument("--fps", type=float, default=30)
    tx.add_argument("--drop-index", type=int, help="omit this chunk from every synthetic frame")
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        if args.command == "receive":
            if not math.isfinite(args.seconds) or args.seconds < 0 or args.archive_every < 0:
                raise ValueError("seconds and archive-every must be nonnegative")
            return receive(args, config)
        if args.frames <= 0 or not math.isfinite(args.fps) or args.fps <= 0 or (args.drop_index is not None and args.drop_index < 0):
            raise ValueError("invalid simulation limits")
        return simulate(args, config)
    except (ValueError, OSError) as error:
        print(f"PRAW: {error}", file=sys.stderr)
        return 2
