"""Bounded real UDP commissioning check; save statistics, never video payloads.

Use the unchanged host decoder/reassembler. TEST pixels are verified against
the FPGA's documented pattern; neither synthetic content nor host arrival
time is evidence of camera capture, FPGA latency or HDMI output.
"""
import argparse
from collections import Counter, deque
import hashlib
import json
from pathlib import Path
import socket
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from pango_video.protocol import FormatLimits
from pango_video.reassembly import FrameAssembler


def expected_pixels(fid):
    """Construct two 1920-byte row types; repeat their 32-line vertical bands."""
    rows = [bytes(((x + fid) & 255) if (((x >> 5) ^ parity) & 1) else 0x20
                  for x in range(1920)) for parity in (0, 1)]
    return b''.join(rows[(y >> 5) & 1] for y in range(1080))


def receive(boot, seconds, wait_first):
    """Verify only the explicitly configured peer/epoch; never send packets."""
    peer = (boot['source_ip'], boot['source_port'])
    bind = (boot['peer_ip'], boot['peer_port'])
    assembler = FrameAssembler(device_id='PG2L100H-MINI-TEST', stream_epoch=boot['epoch'],
                               format_limits=FormatLimits(1920, 1080, expected_bayer_code=1))
    counts = Counter()
    samples = deque(maxlen=8)
    failures = deque(maxlen=16)
    first = last = None
    started = time.monotonic()
    deadline = started + wait_first
    buffer = bytearray(65535)
    # Exclusive bind and a bounded socket buffer; do not edit firewall/NIC settings.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        actual_buffer = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        sock.bind(bind)
        sock.settimeout(0.02)
        print(json.dumps(dict(event='LISTENING', bind=bind, peer=peer,
                              epoch=boot['epoch'], source='FPGA SYNTHETIC TEST')), flush=True)
        next_update = started + 5
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_update:
                print(json.dumps(dict(event='PROGRESS', counters=dict(counts))), flush=True)
                next_update = now + 5
            try:
                size, sender = sock.recvfrom_into(buffer)
            except socket.timeout:
                assembler.expire()
                continue
            counts['udp_packets'] += 1
            counts['udp_bytes'] += size
            if sender != peer:
                counts['wrong_peer'] += 1
                continue
            # Start the observation window on the first matching physical peer.
            if first is None:
                first = time.monotonic()
                deadline = first + seconds
            frame = assembler.feed(memoryview(buffer)[:size])
            for failure in assembler.drain_failures():
                counts['assembly_failures'] += 1
                failures.append(dict(reason=failure.reason, key=failure.key,
                                     received=failure.received_packets, expected=failure.packet_count))
            if frame is None:
                continue
            h = frame.header
            counts['complete_frames'] += 1
            if h.descriptor_id != 0x54534554 or h.param_version != 0:
                counts['wrong_test_identity'] += 1
            elif frame.data != expected_pixels(h.frame_id):
                counts['pixel_mismatches'] += 1
            else:
                counts['exact_test_frames'] += 1
                counts['exact_test_bytes'] += len(frame.data)
            last = time.monotonic()
            samples.append(dict(frame_id=h.frame_id, bytes=len(frame.data),
                                sha256=hashlib.sha256(frame.data).hexdigest()))
    # Do not turn the intentional receive-window boundary into a missing frame.
    status = assembler.status()
    elapsed = time.monotonic() - (first if first is not None else started)
    rejected = sum(v for k, v in status['counters'].items()
                   if '_rejected_' in k or k in ('packets_wrong_epoch', 'packets_descriptor_conflict'))
    passed = (counts['exact_test_frames'] >= 3 and not counts['wrong_test_identity']
              and not counts['pixel_mismatches'] and not rejected)
    return dict(link_data_passed=passed, source='FPGA SYNTHETIC TEST - NOT CAMERA',
                hardware_received=first is not None, bind=bind, peer=peer,
                epoch=boot['epoch'], receive_buffer_bytes=actual_buffer,
                counters=dict(counts), assembly=status, recent_failures=list(failures),
                recent_frame_hashes=list(samples), elapsed_window_seconds=elapsed,
                complete_fps_in_receive_window=counts['complete_frames']/elapsed,
                first_matching_packet=first is not None, last_complete_seen=last is not None,
                payloads_saved=False, network_settings_changed=False,
                note='Data-path smoke test, not lossless/long-soak/camera/HDMI acceptance')


def main():
    """Require explicit metadata and a fresh output file inside host/reports."""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--boot', type=Path)
    p.add_argument('--out', type=Path)
    p.add_argument('--seconds', type=float, default=10)
    p.add_argument('--wait-first', type=float, default=30)
    p.add_argument('--self-test', action='store_true')
    a = p.parse_args()
    if a.self_test:
        data = expected_pixels(1)
        if len(data) != 2073600 or data[32] != 33 or data[32*1920] != 1 or data[0] != 32:
            raise ValueError('TEST pattern mismatch')
        print('FPGA_TEST_PATTERN_PASS hardware_opened=false')
        return
    if not a.boot or not a.out or not 0 < a.seconds <= 120 or not 0 < a.wait_first <= 120:
        p.error('boot/out and durations in (0,120] required')
    out = a.out.resolve()
    if not out.is_relative_to(Path(__file__).resolve().parents[1] / 'reports') or out.exists():
        p.error('use a fresh host/reports output')
    boot = json.loads(a.boot.read_text(encoding='utf-8-sig'))
    if boot.get('source') != 'SYNTHETIC TEST - NOT CAMERA' or boot.get('descriptor_id') != '0x54534554':
        p.error('only explicit commissioning TEST metadata accepted')
    result = receive(boot, a.seconds, a.wait_first)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result), flush=True)
    sys.exit(0 if result['link_data_passed'] else 2)


if __name__ == '__main__':
    main()
