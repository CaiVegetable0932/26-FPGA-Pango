"""Audit the latest routed design, image freshness and exact source provenance.

This does not authorize programming. External skew remains a design budget;
the native GPLL startup-model diagnostic is retained as a qualification limit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    """Stream hashes on the project's Python 3.10+ baseline."""
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def source_path(root, recorded):
    """Resolve archived absolute provenance in this checkout after cloud restore.

    Preserve the recorded hashes; do not read another checkout merely because
    the generating machine's absolute directory still happens to exist.
    """
    prefix, separator, relative = recorded.replace('\\', '/').rpartition('/fpga/')
    if not prefix or not separator:
        raise ValueError('source manifest entry is outside fpga/')
    path = (root / relative).resolve()
    if not path.is_relative_to(root):
        raise ValueError('source manifest entry escapes fpga/')
    return path


def audit(run):
    """Reject stale images, altered inputs, wrong clocks or any timing violation."""
    root = Path(__file__).resolve().parents[1]
    impl = root / 'build/mini_comms_bringup/implementation'
    report = impl / 'report_timing/mini_comms_bringup.rtr'
    image = run / 'mini_comms_bringup.sbit'
    text = report.read_text(encoding='utf-8-sig')
    if not re.search(r'^Design Summary\s*:\s*All Constraints Met\.', text, re.M):
        raise ValueError('final min/max timing is not closed')
    for target in ('PG2L100H', 'FBG676', 'Speed Grade  : -6'):
        if target not in text:
            raise ValueError('wrong device/package/speed')
    if not re.search(r'NET125\s+8\.0000\s+\{0\.0000 4\.0000\}', text):
        raise ValueError('missing 125 MHz clock')
    if not re.search(r'PHY_SAMPLE\s+8\.0000\s+\{2\.0000 6\.0000\}', text):
        raise ValueError('PHY 2 ns timing policy missing')
    manifest = json.loads((run / 'source_manifest.json').read_text(encoding='utf-8-sig'))
    changed = [x['path'] for x in manifest if sha(source_path(root, x['path'])).lower() != x['sha256'].lower()]
    if changed:
        raise ValueError(f'inputs changed after native build: {changed}')
    if not image.is_file() or image.stat().st_size < 10000 or image.stat().st_mtime < report.stat().st_mtime:
        raise ValueError('no fresh image after the final timing report')
    # One image under native implementation and one archival copy must match.
    if sha(image) != sha(impl / 'generate_bitstream/mini_comms_bringup.sbit'):
        raise ValueError('archive/native image mismatch')
    pairs = []
    section = None
    for line in text.split('Slow Corner\n')[0].splitlines():
        heading = re.match(r'(Setup|Hold|Recovery|Removal) Summary\((Slow|Fast) Corner\)', line)
        if heading:
            section = '_'.join(heading.groups())
        elif line.startswith('Minimum Pulse Width'):
            section = None
        row = re.match(r'\s+(NET125)\s+(NET125|PHY_SAMPLE)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$', line)
        if section and row:
            a,b,slack,total,failed,count=row.groups()
            if float(slack)<0 or int(failed):
                raise ValueError('negative timing row')
            pairs.append(dict(section=section,launch=a,capture=b,slack_ns=float(slack),endpoints=int(count)))
    if len(pairs)!=12:
        raise ValueError(f'incomplete min/max timing summaries: {len(pairs)}')
    return dict(timing_constraints_met=True, source_hashes_match=True, checked_inputs=len(manifest),
                bitstream=str(image),bitstream_sha256=sha(image),bytes=image.stat().st_size,
                timing_report=str(report), timing_sha256=sha(report), timing_pairs=pairs,
                image_kind='SYNTHETIC communications commissioning candidate; NOT camera/HDMI',
                programmed=False, hardware_tested=False, physical_mcu_wiring_confirmed=False,
                pcb_skew_measured=False, pll_native_strict_simulation_passed=False,
                pll_model_note='Unmodified GTP_GPLL.v:1026 initialization division diagnostic in ModelSim10.1c; 1000 period/phase assertions pass; strict simulation remains failed')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run',type=Path)
    args=parser.parse_args()
    result=audit(args.run.resolve())
    print(json.dumps(result,indent=2))
