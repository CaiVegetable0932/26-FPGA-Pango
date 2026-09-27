"""Exact 64-byte PRAW V1 wire format. Application integers are little endian.

The socket delivers a single UDP payload, not Ethernet/IP/UDP headers. A decoded
payload is a borrowed memoryview: consume it before reusing the receive buffer.
"""

from dataclasses import astuple, dataclass, replace
from enum import IntEnum
from struct import Struct
from typing import Iterator
import zlib


MAGIC = b"PRAW"
VERSION = 1
HEADER_BYTES = 64
CHUNK_BYTES = 1400
MAX_DATAGRAM_BYTES = HEADER_BYTES + CHUNK_BYTES
HEADER_STRUCT = Struct("<4sHHBBHQQIHHIIIHBBHHII")
CRC_FIELD = Struct("<I")
RETRANSMISSION = 1
LAST_CHUNK = 2
assert HEADER_STRUCT.size == HEADER_BYTES


class PacketType(IntEnum):
    RAW_LIVE = 1
    SNAP_S1 = 2
    SNAP_RESULT = 3


class PixelFormat(IntEnum):
    RAW8 = 1
    RGB888 = 2


# Purpose: distinguish byte-exact sensor S0 from board-enhanced Bayer RAW8
# without changing the PRAW V1 packet layout or doing any host-side ISP.
ENHANCED_RAW8_DESCRIPTOR = 0x484E4552
ENHANCED_RAW8_VERSION = 2


def source_stage(header) -> str:
    if header.packet_type != PacketType.RAW_LIVE:
        return "snapshot"
    if (header.descriptor_id == ENHANCED_RAW8_DESCRIPTOR
            and header.param_version == ENHANCED_RAW8_VERSION):
        return "fpga_enhanced_raw8"
    return "S0"


class ProtocolError(ValueError):
    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


@dataclass(frozen=True, slots=True)
class FormatLimits:
    expected_width: int | None = 1920
    expected_height: int | None = 1080
    max_frame_bytes: int = 8 * 1024 * 1024
    expected_bayer_code: int | None = None

    def __post_init__(self):
        if self.max_frame_bytes <= 0:
            raise ValueError("max_frame_bytes must be positive")
        for value in (self.expected_width, self.expected_height):
            if value is not None and not 1 <= value <= 65535:
                raise ValueError("expected dimensions must be positive u16 values")
        if self.expected_bayer_code is not None and self.expected_bayer_code not in (1, 2, 3, 4):
            raise ValueError("invalid expected Bayer code")


@dataclass(frozen=True, slots=True)
class Header:
    magic: bytes
    protocol_version: int
    header_bytes: int
    packet_type: int
    flags: int
    pixel_format: int
    stream_epoch: int
    frame_id: int
    param_version: int
    width: int
    height: int
    row_stride: int
    frame_bytes: int
    payload_offset: int
    payload_bytes: int
    bayer_code: int
    bit_depth: int
    packet_index: int
    packet_count: int
    packet_crc32: int
    descriptor_id: int

    @property
    def key(self) -> tuple[int, int, int, int]:
        return (self.stream_epoch, self.frame_id, self.packet_type, self.descriptor_id)

    @property
    def identity(self) -> tuple[int, int, int]:
        return (self.stream_epoch, self.frame_id, self.packet_type)

    @property
    def invariant(self) -> tuple:
        """Fields that must remain identical throughout one image."""
        return (self.key, self.param_version, self.pixel_format, self.width,
                self.height, self.row_stride, self.frame_bytes, self.bayer_code,
                self.bit_depth, self.packet_count)


@dataclass(frozen=True, slots=True)
class Packet:
    header: Header
    payload: memoryview


def packet_crc32(datagram: bytes | bytearray | memoryview) -> int:
    """ISO-HDLC CRC; zlib already implements the initial/final XOR convention."""
    view = memoryview(datagram)
    crc = zlib.crc32(view[:56])
    crc = zlib.crc32(b"\0\0\0\0", crc)
    return zlib.crc32(view[60:], crc) & 0xFFFFFFFF


def validate_header(h: Header, actual_payload_bytes: int,
                    limits: FormatLimits) -> None:
    if h.magic != MAGIC or h.protocol_version != VERSION or h.header_bytes != HEADER_BYTES:
        raise ProtocolError("version_or_magic")
    if h.flags & ~(RETRANSMISSION | LAST_CHUNK):
        raise ProtocolError("reserved_flags")
    if h.packet_type == PacketType.RAW_LIVE:
        if h.pixel_format != PixelFormat.RAW8 or h.bayer_code not in (1, 2, 3, 4):
            raise ProtocolError("raw_format")
        bytes_per_pixel = 1
        if limits.expected_bayer_code is not None and h.bayer_code != limits.expected_bayer_code:
            raise ProtocolError("unexpected_bayer")
    elif h.packet_type in (PacketType.SNAP_S1, PacketType.SNAP_RESULT):
        if h.pixel_format != PixelFormat.RGB888 or h.bayer_code != 0:
            raise ProtocolError("snapshot_format")
        bytes_per_pixel = 3
    else:
        raise ProtocolError("packet_type")
    if h.bit_depth != 8 or h.width == 0 or h.height == 0:
        raise ProtocolError("dimensions_or_depth")
    if ((limits.expected_width is not None and h.width != limits.expected_width)
            or (limits.expected_height is not None and h.height != limits.expected_height)):
        raise ProtocolError("unexpected_mode")
    if h.row_stride != h.width * bytes_per_pixel:
        raise ProtocolError("noncompact_stride")
    if h.frame_bytes != h.row_stride * h.height or not 0 < h.frame_bytes <= limits.max_frame_bytes:
        raise ProtocolError("frame_length")
    count = (h.frame_bytes + CHUNK_BYTES - 1) // CHUNK_BYTES
    if h.packet_count != count or not 0 <= h.packet_index < count:
        raise ProtocolError("packet_index_or_count")
    offset = h.packet_index * CHUNK_BYTES
    length = min(CHUNK_BYTES, h.frame_bytes - offset)
    if h.payload_offset != offset or h.payload_bytes != length or actual_payload_bytes != length:
        raise ProtocolError("chunk_layout")
    if bool(h.flags & LAST_CHUNK) != (h.packet_index == count - 1):
        raise ProtocolError("last_flag")


def decode_datagram(datagram: bytes | bytearray | memoryview,
                    limits: FormatLimits = FormatLimits()) -> Packet:
    view = memoryview(datagram)
    if not HEADER_BYTES < len(view) <= MAX_DATAGRAM_BYTES:
        raise ProtocolError("datagram_length")
    h = Header(*HEADER_STRUCT.unpack_from(view))
    if packet_crc32(view) != h.packet_crc32:
        raise ProtocolError("crc")
    validate_header(h, len(view) - HEADER_BYTES, limits)
    return Packet(h, view[HEADER_BYTES:].toreadonly())


def encode_packet(header: Header, payload: bytes | bytearray | memoryview) -> bytes:
    """Reference encoder for tests/FPGA vectors; not a PC video forwarding path."""
    validate_header(header, len(payload), FormatLimits(None, None))
    out = bytearray(HEADER_BYTES + len(payload))
    HEADER_STRUCT.pack_into(out, 0, *(getattr(header, name) for name in Header.__dataclass_fields__))
    out[HEADER_BYTES:] = payload
    CRC_FIELD.pack_into(out, 56, packet_crc32(out))
    return bytes(out)


def frame_header(*, stream_epoch: int, frame_id: int, width: int, height: int,
                 packet_type: int = PacketType.RAW_LIVE, param_version: int = 0,
                 bayer_code: int = 1, descriptor_id: int = 0) -> Header:
    raw = packet_type == PacketType.RAW_LIVE
    stride = width * (1 if raw else 3)
    size = stride * height
    count = (size + CHUNK_BYTES - 1) // CHUNK_BYTES
    h = Header(MAGIC, VERSION, HEADER_BYTES, packet_type, LAST_CHUNK if count == 1 else 0,
               PixelFormat.RAW8 if raw else PixelFormat.RGB888, stream_epoch, frame_id,
               param_version, width, height, stride, size, 0, min(size, CHUNK_BYTES),
               bayer_code if raw else 0, 8, 0, count, 0, descriptor_id)
    validate_header(h, h.payload_bytes, FormatLimits(None, None))
    # Check unsigned integer bounds even before a reference packet is generated.
    HEADER_STRUCT.pack(*astuple(h))
    return h


def packetize(data: bytes, **frame_fields) -> Iterator[bytes]:
    h = frame_header(**frame_fields)
    if len(data) != h.frame_bytes:
        raise ValueError("pixel data length does not match the declared frame")
    view = memoryview(data)
    for index in range(h.packet_count):
        offset = index * CHUNK_BYTES
        payload = view[offset:offset + CHUNK_BYTES]
        current = replace(h, packet_index=index, payload_offset=offset,
                          payload_bytes=len(payload),
                          flags=LAST_CHUNK if index == h.packet_count - 1 else 0)
        yield encode_packet(current, payload)
