"""Bind structural-candidate software evidence and enforce the modeled frame budget.

This audit never starts PDS or changes the production readiness gate. Hashes
bind the compiled RTL to the candidate and separate functional proof from
unmeasured mapping, routing, timing and board performance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def digest(path):
    """Hash raw bytes so line-ending or source changes invalidate evidence."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    """Check completed evidence, record all bindings, and fail closed."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--full-frame', type=Path, required=True)
    parser.add_argument('--baseline-frame', type=Path, required=True)
    parser.add_argument('--network', type=Path, required=True)
    parser.add_argument('--cdc', type=Path, required=True)
    parser.add_argument('--host-result', type=Path, required=True)
    parser.add_argument('--units', type=Path, nargs='+', required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    fpga = Path(__file__).resolve().parents[1]
    if not candidate.is_relative_to(fpga / 'build/route_structure_20261024'):
        raise ValueError('Audit output must remain in an isolated candidate')
    manifest = read(candidate / 'sources.json')
    baseline = read(candidate / 'baseline_sources.json')
    checks = {}
    checks['candidate_source_intact'] = all(digest(candidate / 'source' / n) == h for n, h in manifest.items())
    changed = sorted(n for n in manifest if manifest[n] != baseline.get(n))
    checks['declared_changes_only'] = changed == sorted(read(candidate / 'candidate.json')['changed_files'])
    records = {}
    # Independently inspect the actual frozen sources, rather than accepting a
    # PASS token from a different candidate or test profile.
    for label, folder in [('full_frame', args.full_frame), ('baseline_frame', args.baseline_frame), ('network', args.network)]:
        result = read(folder / 'result.json')
        hashes = read(folder / 'sources.json')
        expected = baseline if label == 'baseline_frame' else manifest
        checks[label + '_passed'] = result['passed'] and result['snapshot_intact']
        checks[label + '_source_binding'] = all(digest(folder / 'source' / n) == h and
            (not n.startswith('rtl/') or expected.get(n) == h) for n, h in hashes.items())
        records[label] = dict(directory=str(folder.resolve()), result_sha256=digest(folder / 'result.json'))
    full = read(args.full_frame / 'result.json')
    checks['full_frame_profile'] = all(full.get(k) for k in ['full_frame', 'control_test', 'display_test', 'board_manual_profile'])
    # Baseline comparison is meaningful only with the same simulation fixtures.
    new_hashes = read(args.full_frame / 'sources.json')
    old_hashes = read(args.baseline_frame / 'sources.json')
    checks['baseline_fixtures_match'] = all(old_hashes.get(n) == h for n, h in new_hashes.items() if n.startswith('sim/'))
    log = (args.full_frame / 'run.log').read_text()
    cycles = [int(x) for x in re.findall(r'FRAME_GEOMETRY job=\d+ geometry_cycles=(\d+)', log)]
    checks['three_frame_budget'] = len(cycles) == 3 and max(cycles) * 30 <= 125000000
    checks['display_complete'] = 'DISPLAY_CORE_PASS new=3 repeat=1 checked_pixels=8294400 failed=0 underflow=0' in log
    checks['raw_complete'] = 'TB_VIDEO_MEMORY_CORE_PASS bytes=6220800 good=3 processed=3' in log
    for index, folder in enumerate(args.units):
        result = read(folder / 'result.json')
        checks['unit_' + str(index)] = result['passed'] and result['inputs_intact'] and all(
            digest(folder / n) == h and (not n.startswith('rtl/') or manifest.get(n) == h)
            for n, h in result['inputs'].items())
        records['unit_' + str(index)] = dict(directory=str(folder.resolve()), result_sha256=digest(folder / 'result.json'))
    cdc = read(args.cdc / 'result.json')
    checks['cdc_passed'] = cdc['passed'] and cdc['snapshot_intact']
    checks['cdc_source_binding'] = all(digest(args.cdc / 'source' / n) == h for n, h in cdc['source_hashes'].items()) and all(
        digest(Path(p)) == h for p, h in cdc['original_hashes'].items()) and Path(cdc['rtl_origin']).resolve() == candidate / 'source'
    host = read(args.host_result)
    checks['host_decoder_passed'] = host['passed'] and host['companion_snapshot_intact']
    checks['host_vector_binding'] = Path(host['input_directory']).resolve() == args.network.resolve() and all(
        digest(args.network / n) == h for n, h in host['input_sha256'].items()) and all(
        digest(Path(host['companion_snapshot_directory']) / n) == h for n, h in host['companion_files_sha256'].items())
    records['cdc'] = dict(directory=str(args.cdc.resolve()), result_sha256=digest(args.cdc / 'result.json'))
    records['host'] = dict(path=str(args.host_result.resolve()), sha256=digest(args.host_result))
    result = dict(passed=all(checks.values()), checks=checks, evidence=records, changed_files=changed,
                  geometry_cycles=cycles, clock_hz=125000000, minimum_fps=30,
                  pds_run=False, physical_signed_off=False, hardware_tested=False,
                  production_selected=False, bitstream_generation_allowed=False)
    (candidate / 'software_evidence.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
