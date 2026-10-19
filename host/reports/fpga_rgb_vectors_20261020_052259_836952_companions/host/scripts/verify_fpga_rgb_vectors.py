"""Verify synthetic RTL UART/PRAW vectors with the actual host codecs.

This reads files only. It never opens hardware or a network socket. Evidence
is saved under host/reports and remains explicitly synthetic/unverified.
"""
import argparse
from datetime import datetime
import hashlib
import importlib
import json
from pathlib import Path
import subprocess
import sys

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / 'src'))
from pango_video.fpga_rgb_control import reply, snapshot_descriptor
from pango_video.protocol import decode_datagram, FormatLimits

# Purpose: freeze the exact offline import closure with every verification.
# raw8_boot imports cli for metadata validation, which imports the portable
# receiver/storage/reassembly core; Linux batch IO is optional and never used
# by this file-only verification. No serial/network hardware is opened here.
COMPANION_MODULES = ('__init__', 'fpga_rgb_control', 'raw8_boot', 'protocol',
                     'cli', 'reassembly', 'receiver', 'storage')
COMPANION_FILES = ('host/scripts/verify_fpga_rgb_vectors.py',) + tuple(
    'host/src/pango_video/'+name+'.py' for name in COMPANION_MODULES)


def companion_digest(path):
    """Hash actual companion bytes before/after the offline worker runs."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def freeze_companions(snapshot):
    """Copy nine inputs once; the worker must import these frozen bytes.

    Recording current source hashes beside a past PASS would be misleading.
    Each new invocation therefore gets a fresh snapshot and reruns the actual
    decoding process with that snapshot's script/module paths.
    """
    snapshot.mkdir(parents=True, exist_ok=False)
    hashes = {}
    origins = {}
    project = HOST.parent
    for name in COMPANION_FILES:
        origin = project / name
        data = origin.read_bytes()
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
        origins[name] = str(origin.resolve())
    (snapshot / 'companion_snapshot_manifest.json').write_text(json.dumps(
        {'schema': 'pango_video.offline_companion_snapshot.v1',
         'files': hashes, 'original_paths': origins}, indent=2)+'\n', encoding='utf-8')
    return hashes


def verify_frozen_environment():
    """Require all actual imports and this script to belong to the snapshot.

    Top-level imports have already resolved in the isolated worker. Explicitly
    importing the complete small closure here makes its provenance observable,
    including helper modules not called by the particular vector fixture.
    """
    snapshot = HOST.parent.resolve()
    manifest = json.loads((snapshot / 'companion_snapshot_manifest.json').read_text(encoding='utf-8'))
    hashes = manifest['files']
    if set(hashes) != set(COMPANION_FILES):
        raise ValueError('frozen companion manifest must contain the exact nine files')
    if Path(__file__).resolve() != snapshot / 'host/scripts/verify_fpga_rgb_vectors.py':
        raise ValueError('verification script is outside frozen companion snapshot')
    paths = {}
    for name in COMPANION_MODULES:
        module_name = 'pango_video' if name == '__init__' else 'pango_video.'+name
        module = importlib.import_module(module_name)
        actual = Path(module.__file__).resolve()
        expected = snapshot / ('host/src/pango_video/'+name+'.py')
        if actual != expected:
            raise ValueError('offline decoder imported outside snapshot: '+module_name)
        paths[module_name] = str(actual)
    for name, expected in hashes.items():
        if companion_digest(snapshot / name) != expected:
            raise ValueError('immutable companion input changed: '+name)
    return snapshot, hashes, paths


def verify(folder, width, height):
    """Check independently decoded packet identity, CRC and exact coverage."""
    result = {'passed': False, 'source': 'synthetic RTL UART/GMII fixture',
              'hardware_tested': False, 'input_directory': str(folder)}
    hashes = {}
    replies = folder / 'runtime_replies.bin'
    if replies.is_file():
        data = replies.read_bytes()
        hashes[replies.name] = hashlib.sha256(data).hexdigest()
        expected = [(0x71, 0), (0x90, 0), (0x90, 0), (0x92, 0), (0x92, 4), (0x92, 11),
                    (0x94, 0), (0x94, 11), (0x94, 11), (0x95, 0), (0x93, 0), (0x93, 4)]
        if len(data) == 17*42:
            expected += [(0x96, 0), (0x96, 0), (0x97, 0), (0x90, 0), (0x97, 11)]
        if len(data) != len(expected) * 42:
            raise ValueError('missing UART replies')
        for index, (command, code) in enumerate(expected):
            decoded = reply(data[index*42:(index+1)*42])
            if (decoded['sequence'], decoded['command'], decoded['code']) != (index+1, command, code):
                raise ValueError('UART sequence/status differs')
        result['uart_replies'] = len(expected)
    wire = folder / 'snapshot_datagrams.bin'
    if wire.is_file():
        data = wire.read_bytes()
        hashes[wire.name] = hashlib.sha256(data).hexdigest()
        position = 0
        offsets = {2: [], 3: []}
        packets = 0
        limits = FormatLimits(expected_width=width, expected_height=height)
        while position < len(data):
            size = int.from_bytes(data[position:position+2], 'little')
            position += 2
            if not 64 <= size <= 1464 or position + size > len(data):
                raise ValueError('truncated datagram record')
            packet = decode_datagram(data[position:position+size], limits)
            position += size
            h = packet.header
            if h.packet_type not in offsets or h.pixel_format != 2 or h.stream_epoch != 0xf123456789abcdef or h.frame_id != 1:
                raise ValueError('wrong snapshot source identity/format')
            if h.descriptor_id != h.packet_type-1 or h.frame_bytes != width*height*3 or h.row_stride != width*3 or h.bayer_code != 0:
                raise ValueError('wrong snapshot descriptor/compact layout')
            if bytes(packet.payload) != bytes([73])*h.payload_bytes:
                raise ValueError('snapshot pixel bytes differ')
            offsets[h.packet_type].append((h.payload_offset, h.payload_bytes))
            packets += 1
        for spans in offsets.values():
            expected_offset = 0
            for offset, size in sorted(spans):
                if offset != expected_offset:
                    raise ValueError('gap or duplicate snapshot coverage')
                expected_offset += size
            if expected_offset != width*height*3:
                raise ValueError('incomplete snapshot')
        result.update(snapshot_packets=packets, snapshot_bytes=width*height*3*2,
                      width=width, height=height)
    descriptors = folder / 'snapshot_descriptors.bin'
    if descriptors.is_file():
        data = descriptors.read_bytes()
        if len(data) != 288:
            raise ValueError('incomplete snapshot parameter records')
        decoded = [snapshot_descriptor(data[i:i+96]) for i in (0, 96)]
        for index, record in enumerate(decoded):
            if record['epoch'] != 0xf123456789abcdef or record['frame_id'] != 1 or record['descriptor_id'] != index+1 or record['stage'] != index+1:
                raise ValueError('snapshot record differs from PRAW identity')
            if record['pose_status'] != 1 or record['errors'] != 0 or record['width'] != width or record['height'] != height:
                raise ValueError('snapshot metadata invalid')
        entity = data[192:]
        if int.from_bytes(entity[72:76], 'little') != 1 or int.from_bytes(entity[84:92], 'little') != 1:
            raise ValueError('snapshot geometry version/source differs')
        hashes[descriptors.name] = hashlib.sha256(data).hexdigest()
        result['snapshot_descriptors'] = decoded
    if not hashes:
        raise ValueError('no synthetic vectors found')
    result.update(passed=True, input_sha256=hashes)
    return result


def main():
    """Freeze the decoder, rerun it offline, and bind only this new evidence.

    The private worker flag is an internal re-execution mechanism. It neither
    sends packets nor compiles FPGA logic; all model/vector inputs are read-only.
    Historical verification reports are preserved and are not retroactively
    labelled as having used this newly recorded companion snapshot.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--width', type=int, default=35)
    parser.add_argument('--height', type=int, default=33)
    parser.add_argument('--_frozen-worker-report', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args._frozen_worker_report:
        snapshot, hashes, import_paths = verify_frozen_environment()
        output = args._frozen_worker_report.resolve()
        # The parent creates snapshots directly under its original reports
        # directory. Keep worker evidence alongside that snapshot, never in
        # the immutable nine-file import tree or an arbitrary supplied folder.
        if output.parent != snapshot.parent or output.exists():
            raise ValueError('worker report must be fresh and beside its snapshot')
        result = verify(args.run.resolve(), args.width, args.height)
        intact = all(companion_digest(snapshot / name) == expected for name, expected in hashes.items())
        if not intact:
            raise ValueError('frozen companions changed while decoding')
        result.update(companion_snapshot_directory=str(snapshot),
                      companion_files_sha256=hashes,
                      verification_script_path=str(Path(__file__).resolve()),
                      companion_import_paths=import_paths,
                      companion_snapshot_intact=intact,
                      verification_environment='isolated frozen companion process')
        output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(result))
        print(output)
        return
    stamp = datetime.now().strftime('fpga_rgb_vectors_%Y%m%d_%H%M%S_%f')
    output = HOST / 'reports' / (stamp+'.json')
    snapshot = HOST / 'reports' / (stamp+'_companions')
    freeze_companions(snapshot)
    worker = snapshot / 'host/scripts/verify_fpga_rgb_vectors.py'
    command = [sys.executable, '-I', '-B', str(worker), '--run', str(args.run.resolve()),
               '--width', str(args.width), '--height', str(args.height),
               '--_frozen-worker-report', str(output)]
    completed = subprocess.run(command, cwd=snapshot, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=180)
    (HOST / 'reports' / (stamp+'.worker.log')).write_bytes(completed.stdout)
    sys.stdout.buffer.write(completed.stdout)
    if completed.returncode:
        raise SystemExit(completed.returncode)
    recorded = json.loads(output.read_text(encoding='utf-8'))
    if not recorded.get('passed') or not recorded.get('companion_snapshot_intact'):
        raise RuntimeError('frozen decoder did not produce a complete verification')


if __name__ == '__main__':
    main()
