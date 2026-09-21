"""Prepare an explicit SYNTHETIC-stream commissioning command, offline only.

Never opens a serial port/socket or changes a PC network setting. The generated
epoch is fresh per invocation; do not reuse a saved command after board reset.
Outputs belong to fpga/. Measured captures are not produced by this script.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import secrets
import struct
import time


def crc16(data):
    """Independent CCITT-FALSE envelope checksum, returned as an integer."""
    c = 0xffff
    for octet in data:
        c ^= octet << 8
        for _ in range(8):
            c = ((c << 1) ^ (0x1021 if c & 0x8000 else 0)) & 0xffff
    return c


def mac(text):
    """Require explicit unicast MACs; no broadcast/discovery fallback."""
    raw = bytes.fromhex(text.replace(':', '').replace('-', ''))
    if len(raw) != 6 or not any(raw) or raw[0] & 1:
        raise ValueError('MAC must be six nonzero unicast bytes')
    return raw


def ipv4(text):
    """Match the commissioning RTL's first-octet admissibility checks."""
    raw = ipaddress.IPv4Address(text).packed
    if raw[0] == 0 or raw[0] >= 224:
        raise ValueError('IPv4 destination/source must be explicit unicast')
    return raw


def make_command(epoch, source_mac, peer_mac, source_ip, peer_ip, source_port=50001, peer_port=50000):
    """Serialize wire-order addresses but little-endian epoch/ports/CRC."""
    if not 0 < epoch < 2**64 or not all(0 < x < 65536 for x in (source_port, peer_port)):
        raise ValueError('nonzero epoch and ports required')
    payload = (struct.pack('<Q', epoch) + mac(source_mac) + mac(peer_mac) +
               ipv4(source_ip) + ipv4(peer_ip) + struct.pack('<HH', source_port, peer_port))
    body = struct.pack('<BBHH', 1, 0x70, 1, len(payload)) + payload
    return b'\x55\xaa' + body + struct.pack('<H', crc16(body))


def self_test():
    """Cross-check the RTL test-vector layout and reject unsafe peer inputs."""
    if crc16(b'123456789') != 0x29b1:
        raise ValueError('CRC16 known vector failed')
    args = (0x0102030405060708, '02:00:00:00:00:01', '02:00:00:00:00:02', '192.168.1.50', '192.168.1.100')
    wire = make_command(*args)
    expected = bytes.fromhex('0807060504030201020000000001020000000002c0a80132c0a8016451c350c3')
    if len(wire) != 42 or wire[8:-2] != expected or int.from_bytes(wire[-2:], 'little') != crc16(wire[2:-2]):
        raise ValueError('boot wire-order test failed')
    for bad in ('00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff', '01:00:00:00:00:01', 'abcd'):
        try:
            mac(bad)
        except ValueError:
            continue
        raise ValueError('unsafe MAC accepted')
    print('COMMS_BOOT_ENCODER_PASS tests=6 hardware_opened=false')


def main():
    """Generate reviewable hex/metadata only after explicit TEST acknowledgment."""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--self-test', action='store_true')
    p.add_argument('--acknowledge-synthetic', action='store_true')
    for key in ('source-mac', 'peer-mac', 'source-ip', 'peer-ip', 'out'):
        p.add_argument('--' + key)
    p.add_argument('--source-port', type=int, default=50001)
    p.add_argument('--peer-port', type=int, default=50000)
    a = p.parse_args()
    if a.self_test:
        self_test()
        return
    if not a.acknowledge_synthetic or not all((a.source_mac, a.peer_mac, a.source_ip, a.peer_ip, a.out)):
        p.error('explicit peers, --out and --acknowledge-synthetic are required')
    epoch = secrets.randbits(64) or 1
    command = make_command(epoch, a.source_mac, a.peer_mac, a.source_ip, a.peer_ip, a.source_port, a.peer_port)
    folder = Path(a.out).resolve()
    if not folder.is_relative_to(Path(__file__).resolve().parents[1]):
        p.error('output must remain inside this checkout fpga/ development area')
    folder.mkdir(parents=True, exist_ok=False)
    (folder / 'boot.hex').write_text(command.hex(' ') + '\n', encoding='ascii')
    metadata = dict(source='SYNTHETIC TEST - NOT CAMERA', epoch=epoch, epoch_hex=f'{epoch:016x}',
                    descriptor_id='0x54534554', created_ns=time.time_ns(), command_hex=command.hex(),
                    uart='CP2102,115200,8N1; not confirmed MCU header wiring',
                    warning='one boot only; STOP with reset; no ARP/RX/ICMP; never reuse after reset',
                    serial_opened=False, network_opened=False, hardware_tested=False,
                    source_mac=a.source_mac, peer_mac=a.peer_mac, source_ip=a.source_ip,
                    peer_ip=a.peer_ip, source_port=a.source_port, peer_port=a.peer_port)
    (folder / 'boot.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(f'Offline TEST command prepared: {folder}; nothing sent to hardware')


if __name__ == '__main__':
    main()
