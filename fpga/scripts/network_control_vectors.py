"""Create deterministic offline vectors using the existing host/MCU codecs.

All outputs are under fpga/sim or fpga/build; no UART/network/hardware access.
Ethernet checksums are independent of the RTL implementation.
"""
from pathlib import Path
import argparse
import json
import struct
import sys
import zlib

FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA.parent
sys.path.insert(0, str(ROOT / "host" / "src"))
from pango_video.protocol import decode_datagram, FormatLimits, packetize
import mcu_pose_v2


def checksum(data: bytes) -> int:
    """RFC 768/791 ones-complement reference including odd final byte."""
    if len(data) & 1:
        data += b"\0"
    total = sum(struct.unpack(f">{len(data)//2}H", data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def vectors(out: Path) -> None:
    """Share real MCU vectors and additional adversarial streams with RTL."""
    out.mkdir(parents=True, exist_ok=True)
    source = json.loads((ROOT / "mcu/tests/vectors.json").read_text())
    state = bytes.fromhex(source["STATE"])
    nested = mcu_pose_v2.encode(0x80, 9, b"garbage" + state)
    corrupt = bytearray(nested)
    corrupt[-1] ^= 1
    cases = {
        "state": state,
        "nested_bad_crc": bytes(corrupt),
        "bad_length_then_state": b"\x55\xaa\x02\x81\0\0\xff\xff" + state,
        "bad_version_then_state": b"\x55\xaa\x01\x81\0\0\0\0" + state,
        "payload_magic": mcu_pose_v2.encode(0x80, 5, b"\x55\xaa" * 4),
    }
    for name, data in cases.items():
        (out / f"{name}.hex").write_text("\n".join(f"{v:02x}" for v in data) + "\n")
    # A real padded Ethernet ARP reply including independent Ethernet FCS.
    local = bytes.fromhex("020000000001")
    peer = bytes.fromhex("020000000002")
    arp = (local + peer + bytes.fromhex("08060001080006040002") + peer
           + bytes.fromhex("c0a85002") + local + bytes.fromhex("c0a85003"))
    body = arp.ljust(60, b"\0")
    wire = b"\x55"*7+b"\xd5"+body+struct.pack("<I", zlib.crc32(body))
    (out / "arp_reply.hex").write_text("\n".join(f"{v:02x}" for v in wire)+"\n")
    # Odd/even UDP checksum and dual-bank overlap golden bytes, independent of
    # RTL. A packet is admitted only after its whole image is buffered.
    golden = bytearray()
    for index, size in enumerate((1, 31, 1399, 1400)):
        app = next(packetize(bytes((i*3+index)&255 for i in range(size)),
                             stream_epoch=17, frame_id=index, width=size, height=1,
                             bayer_code=1, param_version=7, descriptor_id=19))
        (out / f"tiny_header_{index}.hex").write_text("\n".join(f"{v:02x}" for v in app[:56]+b"\0"*4+app[60:64])+"\n")
        ip = bytearray(struct.pack(">BBHHHBBH4s4s", 0x45, 0, len(app)+28, 0, 0x4000, 64, 17, 0,
                                  bytes.fromhex("c0a85003"), bytes.fromhex("c0a85002")))
        struct.pack_into(">H", ip, 10, checksum(bytes(ip)))
        udp = bytearray(struct.pack(">HHHH", 50001, 50000, len(app)+8, 0)+app)
        pseudo = ip[12:20]+b"\0\x11"+struct.pack(">H", len(udp))
        struct.pack_into(">H", udp, 6, checksum(bytes(pseudo+udp)) or 65535)
        body = peer+local+b"\x08\0"+ip+udp
        golden += b"\x55"*7+b"\xd5"+body+struct.pack("<I", zlib.crc32(body))
    (out / "tiny_wire.hex").write_text("\n".join(f"{v:02x}" for v in golden)+"\n")
    (out / "cases.json").write_text(json.dumps({n: len(d) for n, d in cases.items()}, indent=2)+"\n")
    # Full frame values distinguish adjacent rows from forbidden DDR padding.
    raw = bytes((r * 7 + c * 3 + 17) & 255 for r in range(1080) for c in range(1920))
    (out / "source.raw").write_bytes(raw)
    packets = list(packetize(raw, stream_epoch=0x102030405060708,
                            frame_id=19, width=1920, height=1080,
                            param_version=7, descriptor_id=0x12345678, bayer_code=4))
    for index in (0, 1, 1481):
        (out / f"praw_{index}.bin").write_bytes(packets[index])
    (out / "manifest.json").write_text(json.dumps(dict(
        origin="existing host PRAW V1 and mcu/tests/vectors.json", hardware_tested=False,
        source_bytes=len(raw), packets=len(packets), last_payload=200,
        crc_check=f"{zlib.crc32(b'123456789'):08x}"), indent=2)+"\n")


def verify_wire(run: Path) -> dict:
    """Scoreboard every emitted byte, PRAW CRC, UDP/IP checksum and MAC FCS."""
    source = (FPGA / "sim/vectors/network_control/source.raw").read_bytes()
    coverage = bytearray(len(source))
    frames = 0
    arp_frames = 0
    for line in (run / "wire.hex").read_text().splitlines():
        wire = bytes.fromhex(line)
        assert wire[:8] == b"\x55" * 7 + b"\xd5"
        body, fcs = wire[8:-4], wire[-4:]
        assert len(body) >= 60 and struct.unpack("<I", fcs)[0] == zlib.crc32(body)
        if body[12:14] == b"\x08\x06":
            assert body[:6] == b"\xff"*6 and body[20:22] == b"\0\1"
            assert body[38:42] == bytes.fromhex("c0a85002")
            arp_frames += 1
            continue
        assert body[:6] == bytes.fromhex("020000000002")
        assert body[6:14] == bytes.fromhex("0200000000010800")
        ip = body[14:34]
        assert ip[0] == 0x45 and ip[9] == 17 and checksum(ip) == 0
        ip_length = struct.unpack_from(">H", ip, 2)[0]
        assert ip_length == len(body) - 14
        udp = body[34:]
        assert struct.unpack_from(">HHH", udp) == (50001, 50000, len(udp))
        pseudo = ip[12:20] + b"\0\x11" + struct.pack(">H", len(udp))
        assert struct.unpack_from(">H", udp, 6)[0] != 0 and checksum(pseudo + udp) == 0
        packet = decode_datagram(udp[8:], FormatLimits())
        h, payload = packet.header, bytes(packet.payload)
        assert (h.stream_epoch, h.frame_id, h.param_version, h.descriptor_id, h.bayer_code) == (
            0x102030405060708, 19, 7, 0x12345678, 4)
        start, end = h.payload_offset, h.payload_offset + h.payload_bytes
        assert not any(coverage[start:end]) and payload == source[start:end]
        coverage[start:end] = b"\1" * len(payload)
        frames += 1
    assert frames == 1482 and arp_frames == 1 and all(coverage)
    cycles = int((run / "network_cycles.txt").read_text())
    return dict(passed=True, complete_raw_bytes=len(source), ethernet_packets=frames, arp_packets=arp_frames,
                model_clock_hz=125000000, cycles=cycles,
                model_frame_ms=cycles / 125000,
                model_raw_MB_s=len(source)*125 / cycles,
                model_full_fps=125000000 / cycles,
                hardware_tested=False, pnr_tested=False)


def main() -> None:
    """Explicit paths keep official references read-only and outputs reproducible."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        run = args.verify.resolve()
        if not run.is_relative_to(FPGA / "build"):
            parser.error("verification outputs must stay in fpga/build")
        result = verify_wire(run)
        (run / "network_result.json").write_text(json.dumps(result, indent=2)+"\n")
        print(json.dumps(result))
    else:
        vectors(FPGA / "sim/vectors/network_control")


if __name__ == "__main__":
    main()
