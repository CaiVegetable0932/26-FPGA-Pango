"""Independently validate simulated GMII and reassemble it with the real host."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host/src'))
from pango_video.protocol import FormatLimits, decode_datagram
from pango_video.reassembly import FrameAssembler


def check(folder: Path, board_core: bool = False, late_epoch: bool = False) -> dict:
    """Verify wire CRCs, exact geometry and source identity, not just UDP count."""
    # Full-core case includes six frames and native FIFOs, but uses an HMIC BFM.
    prefix = ('late_board' if late_epoch else 'board') if board_core else 'raw8'
    first_id = int(late_epoch)
    frames = 6 - first_id if board_core else 1
    raw = bytes.fromhex((folder / f'{prefix}_gmii.hex').read_text())
    lengths = [int(x) for x in (folder / f'{prefix}_gmii_lengths.txt').read_text().split()]
    limits = FormatLimits(1920, 1080)
    assembler = FrameAssembler(device_id='simulated-raw8-capture',
                              stream_epoch=0x1020304050607080, format_limits=limits)
    offset = 0
    complete = []
    assert len(lengths) == 1482 * frames
    for index, length in enumerate(lengths):
        wire = raw[offset:offset + length]
        offset += length
        assert wire[:8] == b'\x55' * 7 + b'\xd5'
        body = wire[8:-4]
        assert int.from_bytes(wire[-4:], 'little') == zlib.crc32(body)
        assert body[:14] == bytes.fromhex('0200000010010200000000010800')
        ip = body[14:34]
        assert ip[:2] == b'\x45\x00' and ip[9] == 17
        checksum = sum(struct.unpack('!10H', ip))
        while checksum >> 16:
            checksum = (checksum & 65535) + (checksum >> 16)
        assert checksum == 65535
        assert ip[12:] == bytes.fromhex('c0000201c6336402')
        ip_length = int.from_bytes(ip[2:4], 'big')
        src, dst, udp_length, udp_crc = struct.unpack('!4H', body[34:42])
        assert (src, dst, udp_crc) == (50001, 50000, 0)
        assert udp_length + 20 == ip_length <= 1500
        assert len(body) == max(60, ip_length + 14)
        assert not any(body[14 + ip_length:])
        payload = body[42:14 + ip_length]
        h = decode_datagram(payload, limits).header
        assert (h.frame_id, h.packet_type, h.bayer_code) == (first_id + index // 1482, 1, 4)
        assert (h.packet_index, h.packet_count, h.row_stride) == (index % 1482, 1482, 1920)
        # Purpose: the integrated board marks enhanced Bayer RAW8 separately
        # from the standalone byte-exact packetizer transport regression.
        assert (h.param_version, h.descriptor_id, h.frame_bytes) == ((2, 0x484e4552, 2073600) if board_core else (7, 99, 2073600))
        frame = assembler.feed(payload, now_ns=index * 12000)
        if frame is not None:
            complete.append(frame)
    assert offset == len(raw) and len(complete) == frames
    # Purpose: independently model the shared same-phase median and fixed
    # midpoint tone. The result must not depend on the previous frame's dark
    # fraction, while the standalone transport still carries untouched RAW8.
    def tone(value: int) -> int:
        if value <= 24:
            bright = 0
        elif value <= 80:
            bright = (value - 24) * 2
        elif value <= 144:
            delta = value - 80
            bright = 112 + delta + (delta >> 2)
        elif value == 255:
            bright = 255
        else:
            delta = value - 144
            bright = 192 + (delta >> 1) + (delta >> 4) + (delta >> 6)
        if value <= 8:
            dark = 0
        elif value <= 16:
            dark = (value - 8) * 4
        elif value <= 32:
            dark = 32 + (value - 16) * 7
        elif value <= 64:
            dark = 144 + (value - 32) * 2
        elif value <= 128:
            dark = 208 + ((value - 64) >> 1)
        elif value <= 240:
            dark = 240 + ((value - 128) >> 4)
        elif value == 255:
            dark = 255
        else:
            dark = 247 + ((value - 240) >> 1)
        return (bright + dark + 1) >> 1

    def enhanced_row(fid: int, row: int) -> bytes:
        base = (row * 1920 * 17 + fid * 31 + 22) & 255
        samples = bytes((base + x * 17) & 255 for x in range(1920))
        return bytes(tone(sorted((samples[x], samples[x-2], samples[x-4]))[1]
                          if x >= 4 else samples[x]) for x in range(1920))

    hashes = []
    for fid, frame in enumerate(complete, start=first_id):
        expected = ((enhanced_row(fid, 0) + enhanced_row(fid, 1)) * 540 if board_core else
                    bytes((i * 17 + fid * 31 + 22) & 255 for i in range(2073600)))
        assert frame.data == expected
        hashes.append(hashlib.sha256(expected).hexdigest())
    assert assembler.active_frames == 0 and not assembler.drain_failures()
    return dict(passed=True, pixels_per_frame=2073600, frames=frames, first_frame_id=first_id,
                late_epoch_boundary_test=late_epoch, udp_packets=len(lengths),
                raw_sha256=hashes, source='DVP simulation stimulus; behavioral HMIC memory' if board_core else 'DVP stimulus; ideal DDR memory',
                host_reassembly_verified=True, native_fifo_models_verified=board_core,
                gmii_packet_cdc_verified=board_core,
                native_ddr_phy_verified=False,
                hardware_tested=False, physical_camera_source_verified=False,
                external_timing_verified=False, hdmi_source_frame_id=None)


if __name__ == '__main__':
    print(json.dumps(check(Path(sys.argv[1]), '--board-core' in sys.argv[2:], '--late-epoch' in sys.argv[2:]), indent=2))
