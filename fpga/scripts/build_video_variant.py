"""Freeze explicit RTL replacements and run the original board flow through MAP."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
from route_supervisor import run_supervised


def hashes(directory):
    """Hash actual source/IP/constraint bytes, including all original dependencies."""
    return {p.relative_to(directory).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file()}


def main():
    """Never mutate existing builds or live RTL while measuring an isolated variant."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    # Pair repeated arguments by position so a tested multi-file optimization
    # is frozen atomically. A single pair preserves the existing command form.
    parser.add_argument('--relative-source', action='append', required=True)
    parser.add_argument('--replacement', type=Path, action='append', required=True)
    parser.add_argument('--timeout-minutes', type=int, default=60)
    parser.add_argument('--pause-file', type=Path)
    args = parser.parse_args()
    if not 1 <= args.timeout_minutes <= 240:
        parser.error('compile/SYN/MAP budget must be 1..240 minutes')
    fpga = Path(__file__).resolve().parents[1]
    original = args.baseline.resolve()
    if not original.is_relative_to(fpga / 'build'):
        raise ValueError('Baseline must be an FPGA build')
    manifest = json.loads((original / 'sources.json').read_text(encoding='utf-8'))
    if hashes(original / 'source') != manifest:
        raise ValueError('Baseline sources changed')
    if len(args.relative_source) != len(args.replacement):
        raise ValueError('Each relative RTL source requires one replacement file')
    replacements = {}
    for name, origin in zip(args.relative_source, args.replacement):
        relative = Path(name).as_posix()
        if relative not in manifest or not relative.startswith('rtl/'):
            raise ValueError('Replacement must name an existing RTL file: '+relative)
        if relative in replacements:
            raise ValueError('Duplicate RTL replacement: '+relative)
        replacements[relative] = origin.resolve()
    target = original.parent / datetime.now().strftime('delay_%Y%m%d_%H%M%S_%f')
    target.mkdir()
    shutil.copytree(original / 'source', target / 'source')
    for relative, origin in replacements.items():
        shutil.copyfile(origin, target / 'source' / relative)
    candidate = hashes(target / 'source')
    differences = {n: {'original': h, 'candidate': candidate.get(n)}
                   for n,h in manifest.items() if candidate.get(n)!=h}
    if set(differences)!=set(replacements) or set(candidate)!=set(manifest):
        raise ValueError('Unexpected source differences')
    (target / 'sources.json').write_text(json.dumps(candidate, indent=2)+'\n', encoding='utf-8')
    (target / 'source_differences.json').write_text(json.dumps(differences, indent=2)+'\n', encoding='utf-8')
    flow = (original / 'flow.tcl').read_text(encoding='utf-8')
    if flow.strip().splitlines()[-1].strip()!='dev_map':
        raise ValueError('Original source flow must stop at MAP')
    flow = flow.replace(original.as_posix(), target.as_posix())
    (target / 'flow.tcl').write_text(flow, encoding='utf-8')
    shutil.copyfile(Path(__file__), target / 'build_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), target/'route_supervisor.py')
    (target / 'variant_origin.json').write_text(json.dumps(dict(original_build=str(original),
        replacement_origins={name:str(origin) for name,origin in replacements.items()},
        differences=differences), indent=2), encoding='utf-8')
    print('SOURCE_READY', target, flush=True)
    result = dict(stage='dev_map', native_exit=None, errors=[], snapshot_intact=True,
                  board_routed=False, hardware_tested=False, bitstream_generated=False)
    started = time.time()
    try:
        # Own the full native tree and retain a terminal timeout record.
        supervised = run_supervised(
            ['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
             '-file',str(target/'flow.tcl'),'-work_dir',str(target)],
            cwd=target, log_path=target/'console.log',
            timeout_seconds=args.timeout_minutes*60, monitor_path=target/'map_monitor.jsonl',
            pause_path=args.pause_file)
        result['supervision'] = supervised
        result['native_exit'] = supervised['returncode']
        result['errors'] = re.findall(r'^E:.*', (target / 'console.log').read_text(errors='replace'), re.M)
        if supervised['status'] != 'COMPLETED' or result['errors']:
            raise RuntimeError('Native board compile/SYN/MAP failed')
        result['map_completed'] = (target / 'device_map/pango_video_system_map.adf').is_file()
        if not result['map_completed']:
            raise RuntimeError('Native MAP checkpoint missing')
    finally:
        result['snapshot_intact'] = hashes(target / 'source') == candidate
        result['original_snapshot_intact'] = hashes(original / 'source') == manifest
        result['elapsed_seconds'] = time.time()-started
        (target / 'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print(json.dumps(result),flush=True)
    if not result['snapshot_intact'] or not result['original_snapshot_intact']:
        raise RuntimeError('Immutable inputs changed')


if __name__=='__main__':
    main()
