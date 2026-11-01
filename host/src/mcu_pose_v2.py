"""Independent MCU_POSE_V2 byte codec for firmware interoperability checks."""
from __future__ import annotations

import binascii
import struct


def encode(cmd: int, seq: int, payload: bytes = b"") -> bytes:
    if len(payload) > 1024 or not 0 <= cmd <= 255 or not 0 <= seq <= 65535:
        raise ValueError("frame field out of range")
    body = struct.pack("<BBHH", 2, cmd, seq, len(payload)) + payload
    return b"\x55\xaa" + body + struct.pack("<H", binascii.crc_hqx(body, 0xFFFF))


def decode(frame: bytes) -> tuple[int, int, bytes]:
    if len(frame) < 10 or frame[:2] != b"\x55\xaa":
        raise ValueError("invalid header")
    version, cmd, seq, length = struct.unpack_from("<BBHH", frame, 2)
    if version != 2 or length > 1024 or len(frame) != length + 10:
        raise ValueError("invalid version or exact length")
    expected = binascii.crc_hqx(frame[2:-2], 0xFFFF)
    if struct.unpack_from("<H", frame, len(frame) - 2)[0] != expected:
        raise ValueError("CRC mismatch")
    return cmd, seq, frame[8:-2]


def context(boot_id: int, session_id: int) -> bytes:
    if not boot_id or not session_id:
        raise ValueError("nonzero boot and session required")
    return struct.pack("<QI", boot_id, session_id)


def state(payload: bytes) -> dict:
    if len(payload) != 96 or any(payload[68:80]):
        raise ValueError("invalid STATE layout")
    boot, session, config, sample, flags = struct.unpack_from("<QIIII", payload)
    xyz = struct.unpack_from("<iii", payload, 40)
    angles = struct.unpack_from("<ii", payload, 52)
    return {
        "boot_id": boot, "session_id": session, "config_version": config,
        "sample_seq": sample, "status_flags": flags,
        "xyz_normalized_micro": [v if flags & (1 << i) else None for i, v in enumerate(xyz)],
        "pitch_mdeg": angles[0] if flags & 8 else None,
        "yaw_mdeg": angles[1] if flags & 16 else None,
        "imu_tick_us": struct.unpack_from("<Q", payload, 24)[0],
        "xyz_tick_us": struct.unpack_from("<Q", payload, 32)[0],
        "servo_tick_us": struct.unpack_from("<Q", payload, 60)[0],
        "motion_id": struct.unpack_from("<I", payload, 80)[0],
        "latest_event_id": struct.unpack_from("<I", payload, 84)[0],
        "xyz_source": payload[90], "angle_source": payload[91],
        "motion_state": payload[92], "pose_quality": payload[93],
        "fault_code": struct.unpack_from("<H", payload, 94)[0],
        "pose_representation": "gimbal_pitch_yaw", "q_wc": None,
    }
