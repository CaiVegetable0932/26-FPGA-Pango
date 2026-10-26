"""Uncompressed evidence with metadata committed last; no board control commands."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path

from .protocol import PacketType, source_stage
from .reassembly import CompleteFrame


def _sync_directory(path: Path):
    if os.name == "posix":
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def write_committed(path: Path, data: bytes):
    """Only used inside a newly reserved sample directory, never to replace old evidence."""
    partial = path.with_name(path.name + ".part")
    with partial.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(partial, path)
    _sync_directory(path.parent)


def _json_bytes(data: dict) -> bytes:
    return (json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def save_frame(frame: CompleteFrame, destination: Path, *, device_id: str,
               source_mode: str) -> dict:
    """destination must be a NEW directory. metadata.json is its commit marker."""
    if source_mode not in ("mock", "replay", "hardware_unverified"):
        raise ValueError("source_mode must explicitly identify the evidence origin")
    h = frame.header
    if len(frame.data) != h.frame_bytes or not device_id:
        raise ValueError("invalid complete frame or device identity")
    # Storage accepts only complete active RAW protocol frames.
    if h.packet_type != PacketType.RAW_LIVE:
        raise ValueError("unsupported packet type")
    raw = h.packet_type == PacketType.RAW_LIVE
    metadata = {
        "schema": "praw-frame-1", "source_mode": source_mode, "device_id": device_id,
        "saved_utc": datetime.now(timezone.utc).isoformat(),
        "stream_epoch": h.stream_epoch, "frame_id": h.frame_id,
        "packet_type": h.packet_type, "descriptor_id": h.descriptor_id,
        "param_version": h.param_version, "width": h.width, "height": h.height,
        # Purpose: preserve which FPGA stage produced the immutable bytes;
        # enhanced RAW8 remains RAW8 but must not be counted as sensor S0.
        "pixel_format": "RAW8" if raw else "RGB888", "source_stage": source_stage(h), "bit_depth": h.bit_depth,
        "bayer_code": h.bayer_code, "channel_order": None if raw else "RGB",
        "row_stride": h.row_stride, "frame_bytes": h.frame_bytes,
        "file": "image.raw" if raw else "image.rgb",
        "sha256": hashlib.sha256(frame.data).hexdigest(), "hash_origin": "host",
        "packet_count": h.packet_count, "packet_crc32_verified": True,
        "transport_complete": True, "board_frame_hash_verified": False,
        "first_receive_ns": frame.first_receive_ns, "complete_ns": frame.complete_ns,
        "host_clock_domain": "time.monotonic_ns (this process session)",
        "descriptor_status": "unavailable",
        "descriptor": None, "measurement_ready": False,
        "hdmi_source_frame_id": None, "hdmi_pairing_status": "unverified",
    }
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    write_committed(destination / metadata["file"], frame.data)
    write_committed(destination / "metadata.json", _json_bytes(metadata))
    _sync_directory(destination.parent)
    return metadata
