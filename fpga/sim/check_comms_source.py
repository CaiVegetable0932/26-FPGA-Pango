"""Independently verify native RGMII pin samples as PRAW via the existing host."""
from pathlib import Path
import json
import struct
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'host/src'))
from pango_video.protocol import decode_datagram, FormatLimits
from check_ethernet_tx import require, internet_checksum


def check(folder):
    """Check frame identity, L2/IP/UDP checksums, exact geometry and every pixel."""
    data = bytes.fromhex((folder / 'test_rgmii.hex').read_text())
    lengths = [int(x) for x in (folder / 'test_rgmii_lengths.txt').read_text().split()]
    require(len(lengths) == 1482, 'exact datagram count')
    offset = 0
    pixels = bytearray()
    for index, length in enumerate(lengths):
        wire = data[offset:offset+length]
        offset += length
        require(wire[:8] == b'\x55'*7+b'\xd5', 'preamble/SFD')
        body = wire[8:-4]
        require(struct.pack('<I', zlib.crc32(body)) == wire[-4:], 'Ethernet FCS')
        require(body[:14] == bytes.fromhex('0200000000020200000000010800'), 'MAC/EtherType')
        ip = body[14:34]
        require(internet_checksum(ip) == 0, 'IP checksum')
        iplen = int.from_bytes(ip[2:4], 'big')
        require(ip[:2] == b'\x45\x00' and ip[4:10] == b'\0\0\x40\0\x40\x11', 'IP flags/protocol')
        require(ip[12:] == bytes.fromhex('c0a80132c0a80164'), 'IP peer')
        require(len(body) == 14+iplen and iplen <= 1500, 'IP length/MTU')
        require(struct.unpack('!4H', body[34:42]) == (50001, 50000, iplen-20, 0), 'UDP')
        p = decode_datagram(body[42:], FormatLimits(1920, 1080))
        h = p.header
        require((h.stream_epoch, h.frame_id, h.descriptor_id, h.param_version) ==
                (0x0102030405060708, 1, 0x54534554, 0), 'SYNTHETIC TEST identity')
        require((h.packet_index, h.packet_count, h.packet_type, h.bayer_code) == (index,1482,1,1), 'chunk identity')
        pixels.extend(p.payload)
    expected = bytes(((x+1)&255) if ((x>>5)^(y>>5))&1 else 0x20
                     for y in range(1080) for x in range(1920))
    require(pixels == expected and len(pixels) == 2073600, 'every reconstructed test pixel')
    require(offset == len(data), 'trailing wire data')
    return dict(passed=True, source='SYNTHETIC TEST, not camera', native_rgmii=True,
                frames=1, ethernet_packets=1482, exact_pixels=len(pixels), hardware_tested=False)


if __name__ == '__main__':
    print(json.dumps(check(Path(sys.argv[1])), indent=2))
