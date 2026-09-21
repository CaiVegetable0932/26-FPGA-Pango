"""Parse actual RTL GMII output and feed its UDP datagrams to the existing host."""
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host/src'))
from pango_video.protocol import decode_datagram, FormatLimits


def check(folder: Path) -> dict:
    """Check wire checksums/lengths/peer identity and every reassembled pixel."""
    data = bytes.fromhex((folder / 'video_gmii.hex').read_text())
    lengths = list(map(int, (folder / 'video_gmii_lengths.txt').read_text().split()))
    frames = [tuple(map(int, row.split())) for row in
              (folder / 'video_frames.txt').read_text().splitlines()]
    offset = 0
    wire_index = 0
    for fid, w, h, kind, bayer in frames:
        size = w * h * (1 if kind == 1 else 3)
        pixels = bytearray()
        for index in range((size + 1399) // 1400):
            length = lengths[wire_index]
            frame = data[offset:offset + length]
            assert frame[:8] == b'\x55' * 7 + b'\xd5'
            body = frame[8:-4]
            assert int.from_bytes(frame[-4:], 'little') == zlib.crc32(body)
            assert body[:6] == (0x020000001001 + fid).to_bytes(6, 'big')
            assert body[6:12] == (0x020000000001 + fid).to_bytes(6, 'big')
            assert body[12:14] == b'\x08\x00'
            ip = body[14:34]
            assert ip[:2] == b'\x45\x00' and ip[4:10] == b'\0\0\x40\0\x40\x11'
            checksum = sum(struct.unpack('!10H', ip))
            while checksum >> 16:
                checksum = (checksum & 65535) + (checksum >> 16)
            assert checksum == 65535
            assert ip[12:] == bytes.fromhex('c0000201c6336402')
            ip_length = int.from_bytes(ip[2:4], 'big')
            src_port, dst_port, udp_length, udp_checksum = struct.unpack('!4H', body[34:42])
            assert (src_port, dst_port, udp_checksum) == (50001, 50000, 0)
            assert udp_length + 20 == ip_length <= 1500
            assert len(body) == max(60, 14 + ip_length)
            assert not any(body[14 + ip_length:])
            packet = decode_datagram(body[42:14 + ip_length], FormatLimits(w, h))
            head = packet.header
            assert head.stream_epoch == 0x1020304050607080
            assert (head.frame_id, head.packet_type, head.bayer_code) == (fid, kind, bayer)
            assert (head.packet_index, head.param_version, head.descriptor_id) == (index, 7, 99)
            pixels.extend(packet.payload)
            offset += length
            wire_index += 1
        assert pixels == bytes((i * 17 + fid) & 255 for i in range(size))
    assert wire_index == len(lengths) and offset == len(data)
    timing = [tuple(map(int, row.split())) for row in
              (folder / 'video_cycles.txt').read_text().splitlines()]
    fid, size, cycles = next(row for row in timing if row[0] == 22)
    seconds = cycles / 125_000_000
    assert seconds < 1 / 30
    return dict(passed=True, frames=len(frames), ethernet_packets=wire_index,
                gmii_bytes=offset, full_1080p_raw_bytes=size, full_frame_cycles=cycles,
                full_frame_simulated_ms=seconds * 1000,
                simulated_payload_MBps=size / seconds / 1_000_000,
                hardware_tested=False, external_timing_verified=False,
                source='synthetic continuous-source RTL BFM; not measured video')


if __name__ == '__main__':
    print(json.dumps(check(Path(sys.argv[1])), indent=2))
