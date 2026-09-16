"""Uncompressed evidence with metadata committed last; no board control commands."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path

from .protocol import PacketType
from .reassembly import CompleteFrame, SnapshotSpec, validate_specs


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
    descriptor = None
    if frame.descriptor_json is not None:
        spec = SnapshotSpec.from_dict(json.loads(frame.descriptor_json))
        if spec.header.invariant != h.invariant or spec.descriptor["device_id"] != device_id:
            raise ValueError("descriptor does not match frame")
        descriptor = spec.descriptor
    raw = h.packet_type == PacketType.RAW_LIVE
    metadata = {
        "schema": "praw-frame-1", "source_mode": source_mode, "device_id": device_id,
        "saved_utc": datetime.now(timezone.utc).isoformat(),
        "stream_epoch": h.stream_epoch, "frame_id": h.frame_id,
        "packet_type": h.packet_type, "descriptor_id": h.descriptor_id,
        "param_version": h.param_version, "width": h.width, "height": h.height,
        "pixel_format": "RAW8" if raw else "RGB888", "bit_depth": h.bit_depth,
        "bayer_code": h.bayer_code, "channel_order": None if raw else "RGB",
        "row_stride": h.row_stride, "frame_bytes": h.frame_bytes,
        "file": "image.raw" if raw else "image.rgb",
        "sha256": hashlib.sha256(frame.data).hexdigest(), "hash_origin": "host",
        "packet_count": h.packet_count, "packet_crc32_verified": True,
        "transport_complete": True, "board_frame_hash_verified": False,
        "first_receive_ns": frame.first_receive_ns, "complete_ns": frame.complete_ns,
        "host_clock_domain": "time.monotonic_ns (this process session)",
        "descriptor_status": "provided_by_control_adapter" if descriptor else "unavailable",
        "descriptor": descriptor, "measurement_ready": False,
        "hdmi_source_frame_id": None, "hdmi_pairing_status": "unverified",
    }
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    write_committed(destination / metadata["file"], frame.data)
    write_committed(destination / "metadata.json", _json_bytes(metadata))
    _sync_directory(destination.parent)
    return metadata


def save_snapshot_pair(s1: CompleteFrame, result: CompleteFrame, destination: Path, *,
                       device_id: str, source_mode: str) -> dict:
    """Return a durable-pair receipt only after both files and manifest are committed.

    The caller may then request RELEASE and must still verify the board response.
    Power-loss guarantees also depend on OS/filesystem/storage write-cache behavior.
    """
    if s1.descriptor_json is None or result.descriptor_json is None:
        raise ValueError("two explicit snapshot descriptors are required")
    a = SnapshotSpec.from_dict(json.loads(s1.descriptor_json))
    b = SnapshotSpec.from_dict(json.loads(result.descriptor_json))
    validate_specs(a, b, device_id)
    if a.header.invariant != s1.header.invariant or b.header.invariant != result.header.invariant:
        raise ValueError("pair descriptor/header mismatch")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    input_metadata = save_frame(s1, destination / "S1", device_id=device_id, source_mode=source_mode)
    output_metadata = save_frame(result, destination / b.descriptor["tap"],
                                 device_id=device_id, source_mode=source_mode)
    receipt = {"schema": "praw-snapshot-pair-1", "device_id": device_id,
               "source_mode": source_mode, "snapshot_id": a.descriptor["snapshot_id"],
               "stream_epoch": a.header.stream_epoch, "frame_id": a.header.frame_id,
               "input": input_metadata, "output": output_metadata,
               "pair_transport_complete": True, "measurement_ready": False,
               "release_request_eligible": True, "board_release_confirmed": False}
    write_committed(destination / "pair.json", _json_bytes(receipt))
    _sync_directory(destination.parent)
    return receipt
