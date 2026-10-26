"""Independent MCU_POSE_V2 byte codec for firmware interoperability checks.

The 2026-10-21 servo encoder profile keeps this byte layout: each valid angle
source is 1 (both axes pack as 0x05), pose quality is 3, and IMU tick/validity
are zero. GET_CONFIG uses a separate source enumeration: 2 means encoder.
Angle validity relies on zero status and servo timestamps, never IMU presence.
"""
from __future__ import annotations

import binascii
import struct
from collections import Counter


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
    """Validate the whole V2 state before exposing any measurement field.

    Invalid bits hide values; valid bits require legal source/range/zero status.
    This codec does not establish boot/session or physical time synchronization.
    """
    if len(payload) != 96 or any(payload[68:80]):
        raise ValueError("invalid STATE layout")
    boot, session, config, sample, flags = struct.unpack_from("<QIIII", payload)
    xyz = struct.unpack_from("<iii", payload, 40)
    angles = struct.unpack_from("<ii", payload, 52)
    if (not boot or not session or not config or flags & ~0xFFF or payload[88] & ~0x1F or payload[89] & ~0x1F
            or payload[90] & 0xC0 or payload[91] & 0xF0
            or payload[92] not in (0, 1, 2, 3, 5) or payload[93] > 3
            or struct.unpack_from("<H", payload, 94)[0] > 11):
        raise ValueError("invalid STATE flags/source/enum")
    for i, value in enumerate(xyz):
        source = (payload[90] >> (2*i)) & 3
        if source == 3 or flags & (1 << i) and (not 0 <= value <= 100000000 or source not in (1, 2)):
            raise ValueError("invalid normalized XYZ or source")
    for i in range(2):
        source = (payload[91] >> (2*i)) & 3
        if source == 3 or flags & (8 << i) and (not flags & 64 or source not in (1, 2)
                                or not struct.unpack_from("<Q", payload, 60)[0]):
            raise ValueError("invalid angle source/zero/timestamp")
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


class StreamDecoder:
    """Bounded incremental V2 framing with absolute candidate deadlines.

    Mirrors the FPGA discard-one-byte rescan rule. Caller supplies monotonic
    microseconds, including empty feed calls while idle to expire partial frames.
    Returned complete frames are immutable bytes, not references into a buffer.
    """

    def __init__(self, timeout_us: int = 30000, capacity: int = 2048):
        if timeout_us <= 0 or capacity < 1034:
            raise ValueError("invalid decoder bound")
        self.timeout_us = timeout_us
        self.capacity = capacity
        self.buffer = bytearray()
        self.arrival: list[int] = []
        self.stats = Counter()
        self.last_us = -1

    def _discard(self, count: int) -> None:
        """Remove the matching bytes and arrival times together."""
        del self.buffer[:count]
        del self.arrival[:count]

    def feed(self, data: bytes, now_us: int) -> list[bytes]:
        """Consume fragmented input; overflow/discontinuity is always explicit."""
        if now_us < self.last_us:
            raise ValueError("monotonic receive time required")
        self.last_us = now_us
        if len(self.buffer) + len(data) > self.capacity:
            self.stats["overflow"] += 1
            self.buffer.clear()
            self.arrival.clear()
            return []
        self.buffer.extend(data)
        self.arrival.extend([now_us] * len(data))
        self.stats["peak_bytes"] = max(self.stats["peak_bytes"], len(self.buffer))
        frames = []
        while self.buffer:
            if self.buffer[0] != 0x55:
                self._discard(1)
                continue
            if now_us - self.arrival[0] >= self.timeout_us:
                self.stats["timeout"] += 1
                self._discard(1)
                continue
            if len(self.buffer) < 2:
                break
            if self.buffer[1] != 0xAA:
                self._discard(1)
                continue
            if len(self.buffer) < 8:
                break
            length = struct.unpack_from("<H", self.buffer, 6)[0]
            if self.buffer[2] != 2 or length > 1024:
                self.stats["header"] += 1
                self._discard(1)
                continue
            if len(self.buffer) < length + 10:
                break
            frame = bytes(self.buffer[:length+10])
            try:
                decode(frame)
            except ValueError:
                self.stats["crc"] += 1
                self._discard(1)
                continue
            frames.append(frame)
            self._discard(length + 10)
        return frames
