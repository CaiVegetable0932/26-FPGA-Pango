"""Continue one verified FPGA repair through PnR, routed STA and packaging.

This bridge waits for the existing MAP driver to finish, checks real source and
model evidence, then invokes the established native and packaging gates. It
does not program hardware, alter timing constraints, retry alternative seeds,
stop other processes, or modify the shared observation ledger.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def checked_manifest(directory):
    """Reject changed native/model inputs before starting dependent work."""
    manifest = json.loads((directory / 'sources.json').read_text(encoding='utf-8'))
    for name, expected in manifest.items():
        if hashlib.sha256((directory / 'source' / name).read_bytes()).hexdigest() != expected:
            raise ValueError('Source changed: ' + name)
    return manifest


def main():
    """Use one Normal/seed11 physical attempt; downstream errors remain fatal."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--host-report', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    board, model, host = args.board.resolve(), args.model.resolve(), args.host_report.resolve()
    if not board.is_relative_to(fpga / 'build') or not model.is_relative_to(fpga / 'build'):
        raise ValueError('Native/model evidence must remain under fpga/build')
    evidence = board / datetime.now().strftime('completion_%Y%m%d_%H%M%S_%f')
    evidence.mkdir()
    shutil.copyfile(__file__, evidence / 'completion_script.py')
    status = dict(board=str(board), model=str(model), host_report=str(host),
                  stage='waiting_for_map', passed=False, programmed=False)

    def record():
        """Expose milestones without changing the active-process ledger."""
        status['updated_at'] = datetime.now().astimezone().isoformat()
        (evidence / 'result.json').write_text(json.dumps(status, indent=2), encoding='utf-8')
        print(json.dumps(status), flush=True)

    try:
        record()
        deadline = time.monotonic() + 7200
        while True:
            try:
                mapped = json.loads((board / 'result.json').read_text(encoding='utf-8'))
                break
            except (FileNotFoundError, json.JSONDecodeError):
                if time.monotonic() >= deadline:
                    raise TimeoutError('MAP driver did not provide a final result within two hours')
                time.sleep(10)
        if (mapped.get('stage') != 'dev_map' or mapped.get('native_exit') != 0
                or mapped.get('errors') or not mapped.get('map_completed')
                or not mapped.get('snapshot_intact')):
            raise ValueError('MAP driver has not passed')
        native_sources, model_sources = checked_manifest(board), checked_manifest(model)
        shared = native_sources.keys() & model_sources.keys()
        if len(native_sources) != 290 or len(shared) != 70 or any(
                native_sources[n] != model_sources[n] for n in shared):
            raise ValueError('Full board/model identity mismatch')
        result = json.loads((model / 'result.json').read_text(encoding='utf-8'))
        if not all(result.get(k) for k in ('passed', 'full_frame', 'control_test',  'snapshot_intact')):
            raise ValueError('Full-frame model did not pass')
        cycles = int(re.search(r'geometry_cycles=(\d+)', (model / 'run.log').read_text()).group(1))
        if cycles > 125000000 // 30:
            raise ValueError('Measured model frame exceeds the 125MHz/30fps cycle budget')
        host_result = json.loads(host.read_text(encoding='utf-8'))
        if (not host_result.get('passed') or not host_result.get('companion_snapshot_intact')
                or Path(host_result['input_directory']).resolve() != model):
            raise ValueError('Host decode does not bind to this model')
        # Require measured board resource benefit; capacity and timing remain
        # independent gates. DMR includes dedicated physical DRM accounting.
        dmr = (board / 'device_map/pango_video_system.dmr').read_text()
        resources = {}
        for name in ('LUT', 'FF', 'Distributed RAM', 'DRM', 'APM', 'IO'):
            match = re.search(r'^\| ' + re.escape(name) + r'\s+\|\s+(\d+)\s+\|', dmr, re.M)
            if not match:
                raise ValueError('Missing mapped resource: ' + name)
            resources[name] = int(match.group(1))
        if resources['LUT'] >= 44804 or resources['Distributed RAM'] >= 2705 or resources['DRM'] > 155:
            raise ValueError('DMA repair has not demonstrated board resource benefit')
        status.update(stage='native_route_sta_bitgen', mapped_resources=resources,
                      model_geometry_cycles=cycles, shared_rtl_count=len(shared))
        record()
        commands = [
            ('route_sta_bitgen', [sys.executable, str(fpga / 'scripts/resume_video_system.py'),
             '--build', str(board), '--pnr-timeout-minutes', '0', '--phase-timeout-minutes', '0',
             '--placement-seed', '11', '--mode', 'normal', '--placement-decongestion', '1',
             '--control-chain-length', '500', '--congestion-iterations', '200', '--dump-congestion']),
            ('package', [sys.executable, str(fpga / 'scripts/package_video_system.py'),
             '--board-build', str(board), '--simulation', str(model), '--host-verification', str(host)])]
        for stage, command in commands:
            status['stage'] = stage
            record()
            with (evidence / (stage + '.log')).open('wb') as log:
                child = subprocess.run(command, cwd=fpga.parent, stdout=log, stderr=subprocess.STDOUT,
                                       creationflags=0x08000000)
            status[stage + '_exit'] = child.returncode
            if child.returncode:
                raise RuntimeError(stage + ' failed; inspect preserved native evidence')
        status.update(stage='packaged', passed=True)
    except Exception as error:
        status['error'] = str(error)
        raise
    finally:
        record()


if __name__ == '__main__':
    main()
