"""Compare source-bound placement screens without claiming routed signoff.

Only completed native probes contribute metrics. Pending trials stay pending;
positive estimated slack alone cannot select a routable implementation.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    """Bind every completed observation to the exact evidence bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observe(build):
    """Read actual probe output and recheck its frozen inputs before comparing."""
    evidence = build / 'placement_probe'
    result_path = evidence / 'result.json'
    row = dict(build=str(build), status='pending', routed_signoff=False)
    if not result_path.exists():
        return row
    result = json.loads(result_path.read_text(encoding='utf-8'))
    manifest = json.loads((build / 'sources.json').read_text(encoding='utf-8'))
    source_ok = len(manifest) == 290 and all(
        sha(build / 'source' / name) == digest for name, digest in manifest.items())
    checkpoints = result.get('checkpoint_sha256', {})
    checkpoint_ok = len(checkpoints) == 2 and all(
        sha(build / 'device_map' / name) == digest for name, digest in checkpoints.items())
    plc = build / 'place_route/pango_video_system_plc.adf'
    plc_ok = (plc.is_file() and not Path(str(plc) + '.lock').exists()
              and sha(plc) == result.get('placement_sha256'))
    row.update(status='complete' if result.get('passed') else 'failed',
               seed=result.get('placement_seed'),
               decongestion=result.get('placement_decongestion'),
               macro=result.get('macro_policy'),
               planning=result.get('planning_before_place_override'),
               source_manifest_sha256=sha(build / 'sources.json'),
               checkpoints=checkpoints, source_intact=source_ok,
               checkpoints_intact=checkpoint_ok, placement_intact=plc_ok,
               result_sha256=sha(result_path))
    if not (source_ok and checkpoint_ok and plc_ok and result.get('passed')):
        row['status'] = 'unqualified'
        return row
    log = evidence / 'place_only.log'
    content = log.read_text(errors='replace')
    slack = re.findall(r'Worst slack is (-?\d+), TNS after placement is (-?\d+)', content)
    wire = re.findall(r'Wirelength after detailed placement is (\d+)', content)
    duration = re.findall(r'Total placement takes ([\d.]+) sec', content)
    # Resource rows describe physical site occupancy after placement, rather
    # than synthesis LUT totals. Keep vendor-rounded percentages as reported.
    resources = {name.strip(): dict(used=int(used), available=int(total),
                                   utilization_percent=int(percent))
                 for name, used, total, percent in re.findall(
                     r'\| Use of ([^|]+)\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)', content)}
    row.update(log_sha256=sha(log),
               wns_ps=int(slack[-1][0]) if slack else None,
               tns_ps=int(slack[-1][1]) if slack else None,
               wirelength=int(wire[-1]) if wire else None,
               placement_seconds=float(duration[-1]) if duration else None,
               physical_resources=resources,
               detailed_route_convergence=None,
               congestion_comparison='Unavailable from placement-only output')
    return row


def main():
    """Write a comparison only inside FPGA build storage; never alter inputs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / 'build'
    builds = [p.resolve() for p in args.build]
    output = args.output.resolve()
    if not all(p.is_relative_to(root) for p in [*builds, output]):
        raise ValueError('Comparison inputs/output must belong to fpga/build')
    if output.exists():
        raise ValueError('Preserve prior comparisons; choose a new evidence path')
    rows = [observe(b) for b in builds]
    completed = [r for r in rows if r['status'] == 'complete']
    same_inputs = len(completed) > 1 and all(
        (r['checkpoints'], r['source_manifest_sha256']) ==
        (completed[0]['checkpoints'], completed[0]['source_manifest_sha256'])
        for r in completed)
    data = dict(at=datetime.now().astimezone().isoformat(), trials=rows,
                completed_trials_share_inputs=same_inputs, winner=None,
                decision='Placement metrics screen candidates; routed evidence is still required.',
                script_sha256=sha(Path(__file__)))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(data, ensure_ascii=False))


if __name__ == '__main__':
    main()
