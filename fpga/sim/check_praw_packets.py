"""Verify actual RTL output using the existing host PRAW V1 decoder, not an RTL clone."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host/src'))
from pango_video.protocol import decode_datagram, FormatLimits


def check(folder: Path) -> dict:
    """Reassemble every accepted synthetic frame and compare its exact pixel sequence."""
    data = bytes.fromhex((folder / 'praw_packets.hex').read_text())
    lengths = [int(v) for v in (folder / 'praw_lengths.txt').read_text().split()]
    frames = [tuple(map(int, line.split())) for line in (folder / 'praw_frames.txt').read_text().splitlines()]
    pos = 0
    expected_packets = 0
    for w, h, kind, bayer, fid in frames:
        size = w * h * (1 if kind == 1 else 3)
        pixels = bytearray()
        for index in range((size + 1399) // 1400):
            length = lengths[expected_packets]
            packet = decode_datagram(data[pos:pos + length], FormatLimits(w, h))
            head = packet.header
            assert head.stream_epoch == 0x0102030405060708
            assert (head.frame_id, head.packet_type, head.bayer_code) == (fid, kind, bayer)
            assert head.packet_index == index and head.param_version == 0x10203040
            assert head.descriptor_id == 0x55667788
            pixels.extend(packet.payload)
            pos += length
            expected_packets += 1
        assert pixels == bytes((i * 17 + fid) & 255 for i in range(size))
    assert expected_packets == len(lengths) and pos == len(data)
    return dict(passed=True, frames=len(frames), packets=expected_packets, bytes=pos,
                full_1080p_raw=True, hardware_tested=False, source='synthetic RTL BFM')


if __name__ == '__main__':
    report = check(Path(sys.argv[1]))
    print(json.dumps(report, indent=2))
