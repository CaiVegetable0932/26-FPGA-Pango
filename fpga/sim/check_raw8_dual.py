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


def check(folder: Path) -> dict:
    """Verify wire CRCs, exact geometry and source identity, not just UDP count."""
    raw = bytes.fromhex((folder / 'raw8_gmii.hex').read_text())
    lengths = [int(x) for x in (folder / 'raw8_gmii_lengths.txt').read_text().split()]
    limits = FormatLimits(1920, 1080)
    assembler = FrameAssembler(device_id='simulated-raw8-capture',
                              stream_epoch=0x1020304050607080, format_limits=limits)
    offset = 0
    complete = []
    assert len(lengths) == 1482
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
        assert (h.frame_id, h.packet_type, h.bayer_code) == (0, 1, 4)
        assert (h.packet_index, h.packet_count, h.row_stride) == (index, 1482, 1920)
        assert (h.param_version, h.descriptor_id, h.frame_bytes) == (7, 99, 2073600)
        frame = assembler.feed(payload, now_ns=index * 12000)
        if frame is not None:
            complete.append(frame)
    assert offset == len(raw) and len(complete) == 1
    expected = bytes((i * 17 + 22) & 255 for i in range(2073600))
    assert complete[0].data == expected
    assert assembler.active_frames == 0 and not assembler.drain_failures()
    return dict(passed=True, pixels=2073600, udp_packets=1482, capture_frame_id=0,
                raw_sha256=hashlib.sha256(expected).hexdigest(),
                source='DVP simulation stimulus through RTL capture; ideal DDR model',
                host_reassembly_verified=True, native_ddr_cdc_verified=False,
                hardware_tested=False, physical_camera_source_verified=False,
                external_timing_verified=False, hdmi_source_frame_id=None)


if __name__ == '__main__':
    print(json.dumps(check(Path(sys.argv[1])), indent=2))
