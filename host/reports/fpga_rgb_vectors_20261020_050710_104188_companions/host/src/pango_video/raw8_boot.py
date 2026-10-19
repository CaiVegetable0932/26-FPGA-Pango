"""Prepare camera-only boot/receiver metadata offline; never open UART/network."""
import argparse
import ipaddress
import json
from pathlib import Path
import secrets
import struct

from .cli import HOST_ROOT, validate_config
from .protocol import ENHANCED_RAW8_DESCRIPTOR, ENHANCED_RAW8_VERSION


def crc16(data):
    """CCITT-FALSE V1 UART checksum (version through payload)."""
    value = 0xffff
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ (0x1021 if value & 0x8000 else 0)) & 0xffff
    return value


def metadata(epoch, source_mac, peer_mac, source_ip, peer_ip, source_port=50001, peer_port=50000,
             *, enhanced_output=False):
    """Bind one fresh boot epoch and explicitly identify its FPGA RAW8 output stage."""
    if not 0 < epoch < 2**64 or not all(0 < p < 65536 for p in (source_port, peer_port)):
        raise ValueError('nonzero epoch/ports required')
    addresses = []
    for value in (source_mac, peer_mac):
        data = bytes.fromhex(value.replace(':', '').replace('-', ''))
        if len(data) != 6 or not any(data) or data[0] & 1:
            raise ValueError('explicit unicast MAC required')
        addresses.append(data)
    for value in (source_ip, peer_ip):
        data = ipaddress.IPv4Address(value).packed
        if data[0] == 0 or data[0] >= 224:
            raise ValueError('explicit unicast IPv4 required')
        addresses.append(data)
    payload = struct.pack('<Q', epoch) + b''.join(addresses) + struct.pack('<HH', source_port, peer_port)
    body = struct.pack('<BBHH', 1, 0x71, 1, len(payload)) + payload
    wire = b'\x55\xaa' + body + struct.pack('<H', crc16(body))
    # Purpose: the UART boot wire remains unchanged; the recorded PRAW stream
    # identity must match the installed legacy or board-enhanced bitstream.
    descriptor = ENHANCED_RAW8_DESCRIPTOR if enhanced_output else 0x38574152
    version = ENHANCED_RAW8_VERSION if enhanced_output else 1
    boot = dict(source='OV5640 RAW8 - HARDWARE UNVERIFIED', epoch=epoch,
                descriptor_id=f'0x{descriptor:08X}', param_version=version,
                source_stage='fpga_enhanced_raw8' if enhanced_output else 'S0', command_hex=wire.hex(),
                source_mac=source_mac, peer_mac=peer_mac, source_ip=source_ip, peer_ip=peer_ip,
                source_port=source_port, peer_port=peer_port,
                hardware_tested=False, physical_camera_source_verified=False,
                hdmi_source_frame_id=None, bayer_phase_verified=False,
                note='One cold boot only; regenerate after reset. HDMI gray is not ISP S1.')
    receiver = validate_config(dict(device_id='PG2L100H-MINI-CAM1', source_mode='hardware_unverified',
        bind_ip=peer_ip, port=peer_port, peer_ip=source_ip, peer_port=source_port,
        stream_epoch=epoch, width=1920, height=1080, bayer_code=4, receive_buffer_bytes=8388608))
    return boot, receiver


def main():
    """Create fresh host/config files, with no overwrite and no hardware access."""
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('source-mac', 'peer-mac', 'source-ip', 'peer-ip', 'out'):
        parser.add_argument('--' + key, required=True)
    parser.add_argument('--enhanced-output', action='store_true',
                        help='label FPGA-enhanced Bayer RAW8, not unprocessed sensor S0')
    args = parser.parse_args()
    folder = Path(args.out).resolve()
    if not folder.is_relative_to(HOST_ROOT / 'config') or folder.exists():
        parser.error('use a fresh directory under this checkout host/config')
    boot, receiver = metadata(secrets.randbits(64) or 1, args.source_mac, args.peer_mac,
                              args.source_ip, args.peer_ip, enhanced_output=args.enhanced_output)
    folder.mkdir(parents=True)
    for name, data in (('boot.json', boot), ('receiver.json', receiver)):
        (folder / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    print(f'RAW8 offline metadata: {folder}; nothing sent to hardware')


if __name__ == '__main__':
    main()
