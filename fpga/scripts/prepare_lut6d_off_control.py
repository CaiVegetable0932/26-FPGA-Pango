"""Freeze the L MAP into a separate placement-packing OFF control project.

This prepares and hashes inputs only. It does not launch PDS, authorize a
native phase, modify live gates, or copy old placement/routing databases.
"""
from datetime import datetime
from pathlib import Path
import hashlib
import json
import shutil

from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget


def sha(path):
    """Identify the exact bytes supplied to the future physical experiment."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Retain source/MAP identity while relocating writable project outputs."""
    fpga = Path(__file__).resolve().parents[1]
    base = fpga / 'build/full_integration_20261013/board_postsyn_20261023_221908_913042'
    sources = json.loads((base / 'sources.json').read_text(encoding='utf-8'))
    assert all(sha(base / 'source' / n) == h for n,h in sources.items())
    constraints = require_native_constraints(base)
    budget = require_mapped_lut_budget(base)
    run = fpga / 'build/lut6d_off_control_20261025' / datetime.now().strftime('control_%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    target = run / 'L_off'
    target.mkdir()
    for name in ('source', 'synthesize', 'device_map', 'constraint_check'):
        shutil.copytree(base / name, target / name)
    for name in ('sources.json', 'console.log'):
        shutil.copyfile(base / name, target / name)
    shutil.copyfile(base / 'result.json', run / 'historical_L_result.json')
    # Resume reconstructs source/IP registrations from flow.tcl, preserving
    # DDR IDF and native PCF context. Relocate text paths but not DB contents.
    for name in ('flow.tcl', 'flow.pds'):
        original = (base / name).read_text(encoding='utf-8')
        relocated = original.replace(base.as_posix(), target.as_posix()).replace(str(base), str(target))
        (target / name).write_text(relocated, encoding='utf-8')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    for name in ('resume_video_system.py', 'route_supervisor.py', 'constraint_report.py', 'implementation_readiness.py', 'native_bitgen.py'):
        shutil.copyfile(fpga / 'scripts' / name, run / name)
    immutable = ['sources.json', 'device_map/pango_video_system_map.adf', 'device_map/pango_video_system.dmr',
                 'device_map/pango_video_system.pcf', 'synthesize/pango_video_system_syn.adf']
    assert all(sha(base / n) == sha(target / n) for n in immutable)
    assert all(sha(target / 'source' / n) == h for n,h in sources.items())
    assert not (target / 'place_route').exists()
    result = dict(prepared=True, executed=False, baseline=str(base), project=str(target),
        source_count=len(sources), sources_intact=True, mapped_budget=budget,
        new_constraint_gate=require_native_constraints(target),
        original_constraint_gate=constraints,
        immutable_sha256={n:sha(target/n) for n in immutable},
        planned_options=dict(logic_optimize='disabled', placement_seed=13, placement_decongestion=1,
            mode='normal', native_timeout_minutes=90, host_timeout_minutes=90,
            control_chain_length=500, congestion_iterations=200, stop_after_timing=True),
        whole_design_route_allowed=False, bitstream_generation_allowed=False,
        routed=False, hardware_tested=False)
    (run/'preparation_result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    manifest={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    (run/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps(dict(run=str(run),project=str(target),immutable_sha256=result['immutable_sha256']),indent=2))


if __name__ == '__main__':
    main()
