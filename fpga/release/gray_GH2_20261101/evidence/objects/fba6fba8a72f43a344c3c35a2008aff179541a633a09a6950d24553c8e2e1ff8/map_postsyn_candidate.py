"""Derive a MAP-only candidate with explicit post-ADS SCF loading.

PDS 2022.2-SP6.4 UCE guide PDF p11 assigns SCF to MAP. The installed full
ADS project silently omits this overlay, so use the verified explicit SYN DB
entry in a new directory. Preserve the original source, SYN and MAP evidence.
This command never queues compilation, placement, routing or bit generation.
"""
from datetime import datetime
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil

from constraint_report import require_native_constraints, read_constraint_report
from implementation_readiness import require_mapped_lut_budget
from route_supervisor import run_supervised


def sha(path):
    """Bind copied inputs and final native outputs by their exact bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Map an immutable successful SYN candidate; fail closed on lost SCF."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--dry-run', action='store_true')
    # Share the handoff stop request with SYN; no routing follows this stage.
    parser.add_argument('--pause-file', type=Path, help='Graceful stop request for this MAP phase')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    original = args.build.resolve()
    if not original.is_relative_to(fpga / 'build'):
        raise ValueError('Input must be a frozen FPGA build')
    manifest = json.loads((original / 'sources.json').read_text(encoding='utf-8'))
    intact = lambda root: all(sha(root / 'source' / n) == h for n, h in manifest.items())
    prior = json.loads((original / 'result.json').read_text(encoding='utf-8'))
    database = original / 'synthesize/pango_video_system_syn.adf'
    if not intact(original) or prior['native_exit'] != 0 or prior['errors']:
        raise ValueError('Input source or original native result invalid')
    if not database.is_file() or list((original / 'synthesize').glob('*.lock')):
        raise ValueError('Completed unlocked SYN database required')
    scf_name = 'constraints/video_system/reset_fsm_postsyn.scf'
    scf = original / 'source' / scf_name
    if scf_name not in manifest or not scf.is_file():
        raise ValueError('Frozen post-synthesis SCF required')
    out = fpga / 'build/full_integration_20261013' / datetime.now().strftime('board_postsyn_%Y%m%d_%H%M%S_%f')
    out.mkdir()
    # Copy the full source and synthesis products, preserving exact identity;
    # the original MAP remains only historical evidence, never the new MAP.
    for name in ('source', 'synthesize', 'constraint_check'):
        shutil.copytree(original / name, out / name)
    for name in ('sources.json',):
        shutil.copyfile(original / name, out / name)
    shutil.copyfile(original / 'result.json', out / 'parent_result.json')
    # A successful SYN-only parent is sufficient for the first explicit MAP.
    # Preserve an existing historical MAP, but never invent one for SYN-only
    # input or silently ignore a missing report from a claimed MAP parent.
    parent_map = original / 'device_map/pango_video_system.dmr'
    if parent_map.is_file():
        shutil.copyfile(parent_map, out / 'parent_map.dmr')
    elif prior.get('stage') != 'synthesize':
        raise ValueError('Non-SYN parent is missing its historical MAP report')
    shutil.copyfile(__file__, out / 'map_postsyn_candidate.py')
    for name in ('route_supervisor.py', 'constraint_report.py', 'implementation_readiness.py'):
        shutil.copyfile(fpga / 'scripts' / name, out / name)
    # Keep a relocated source-registration prefix for the existing resume
    # tool. This reconstruction script is metadata, not executed this run.
    flow = (original / 'flow.tcl').read_text(encoding='utf-8')
    flow = flow.replace(original.as_posix(), out.as_posix()).replace(str(original), str(out))
    if '\ncompile ' not in flow:
        raise ValueError('Missing source registration boundary')
    (out / 'flow.tcl').write_text(flow, encoding='utf-8')
    copied_db = out / 'synthesize' / database.name
    native = '\n'.join([
        'set_dir -impl_directory {' + out.as_posix() + '}',
        'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676',
        'add_constraint {' + (out / 'source' / scf_name).as_posix() + '}',
        'dev_map -force_to_run -input_db_file {' + copied_db.as_posix() + '}',
    ]) + '\n'
    (out / 'map_only.tcl').write_text(native, encoding='utf-8')
    result = dict(stage='dev_map', parent_build=str(original), native_exit=None,
        errors=[], snapshot_intact=intact(out), syn_sha256=sha(database),
        dry_run=args.dry_run, placement_started=False, routed=False,
        internal_timing_met=False, external_timing_verified=False,
        hardware_tested=False, programmed=False, bitstream_generated=False)
    print('POSTSYN_CANDIDATE', out, flush=True)
    try:
        if not args.dry_run:
            result['supervision'] = run_supervised([
                'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                '-file', str(out / 'map_only.tcl'), '-work_dir', str(out)],
                cwd=out, log_path=out / 'console.log',
                monitor_path=out / 'native_monitor.jsonl', timeout_seconds=900, pause_path=args.pause_file)
            result['native_exit'] = result['supervision']['returncode']
            log = (out / 'console.log').read_text(encoding='utf-8', errors='replace')
            result['errors'] = re.findall(r'^E:.*', log, re.M)
            result['constraint_check'] = read_constraint_report(out / 'constraint_check/constraint_check.ccr')
            result['unmatched_timing_constraints'] = re.findall(r'^[CW]: STA-3015:.*', log, re.M)
            if result['native_exit'] != 0 or result['errors']:
                raise ValueError('Explicit post-synthesis MAP failed')
            # Gate actual report content, not SCF file registration alone.
            result['constraint_gate'] = require_native_constraints(out)
            result['mapped_lut_gate'] = require_mapped_lut_budget(out)
            generated = out / 'map_only.pds'
            if not generated.is_file():
                raise ValueError('Missing native MAP project')
            shutil.copyfile(generated, out / 'flow.pds')
            result['mapped_database_sha256'] = sha(out / 'device_map/pango_video_system_map.adf')
    except Exception as error:
        result['validation_error'] = str(error)
        raise
    finally:
        result['snapshot_intact'] = intact(original) and intact(out)
        result['syn_intact'] = sha(database) == sha(copied_db) == result['syn_sha256']
        (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    if not result['snapshot_intact'] or not result['syn_intact']:
        raise ValueError('Immutable input changed')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
