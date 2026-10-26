"""Bind a completed block-pressure candidate to software and explicit SCF MAP.

This writes review evidence only. It cannot authorize routing, change the
live readiness record, launch PDS or turn failed physical results into signoff.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget
from report_module_resources import parse_hierarchy


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def synthesis(path):
    """Report measured SYN attribution and reset/control-set load separately."""
    text = path.read_text(errors='replace')
    ff_rows = re.findall(r'^\s*(YES|NO)\s+(YES|NO)\s+(YES|NO)\s+(\d+)\s*$', text, re.M)
    # These are synthesis estimates in a named clock domain, not routed STA.
    setup = text.split('Setup Summary(Slow Corner):',1)[1].split('Hold Summary',1)[0]
    ddr = re.search(r'^\s*ddrphy_sysclk\s+ddrphy_sysclk\s+(-?[\d.]+)\s+(-?[\d.]+)', setup, re.M)
    return dict(lut=int(re.search(r'Total LUTs: (\d+)', text)[1]),
        ff=int(re.search(r'Total Registers: (\d+)', text)[1]),
        control_sets=int(re.search(r'Number of unique control sets : (\d+)', text)[1]),
        asynchronous_reset_ff=sum(int(n) for ce, sr, ar, n in ff_rows if ar == 'YES'),
        ddr_domain_setup_wns_ns=float(ddr[1]), ddr_domain_setup_tns_ns=float(ddr[2]),
        modules=parse_hierarchy(text))


def main():
    """Verify hashes and actual completed reports before declaring handoff ready."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['candidate', 'mapping', 'full', 'network', 'host', 'cdc', 'integrity', 'cache-trace']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--software', type=Path, nargs='+', required=True)
    a = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = a.candidate.resolve()
    if not candidate.is_relative_to(fpga / 'build/block_pressure_20261025'):
        raise ValueError('Candidate must remain in its isolated build area')
    identity = read(candidate / 'candidate.json')
    baseline = Path(identity['baseline'])
    hashes = read(candidate / 'sources.json')
    baseline_hashes = read(baseline / 'sources.json')
    checks = dict(candidate_intact=all(sha(candidate / 'source' / n) == h for n,h in hashes.items()),
        baseline_intact=all(sha(baseline / 'source' / n) == h for n,h in baseline_hashes.items()))
    changes = sorted(n for n,h in hashes.items() if baseline_hashes.get(n) != h)
    checks['declared_changes_only'] = changes == sorted(identity['changed_files'])
    evidence = {}
    for label, folder in [('full',a.full),('network',a.network),('mapping',a.mapping)]:
        result = read(folder / 'result.json')
        compiled = read(folder / 'sources.json')
        checks[label + '_source_binding'] = all(sha(folder / 'source' / n) == h and
            (not n.startswith('rtl/') or hashes.get(n) == h) for n,h in compiled.items())
        checks[label + '_completed'] = (result['native_exit'] == 0 and not result['errors'] if label == 'mapping' else result['passed']) and result['snapshot_intact']
        evidence[label] = dict(path=str(folder.resolve()), result_sha256=sha(folder / 'result.json'))
    checks['mapping_complete_manifest'] = read(a.mapping / 'sources.json') == hashes
    constraints = require_native_constraints(a.mapping)
    resources = require_mapped_lut_budget(a.mapping)
    checks['map_constraints'] = True
    checks['map_lut_gate'] = resources['below_70_percent']
    # Frozen FDC/SCF bytes must not be weakened to obtain better resource data.
    checks['constraints_unchanged'] = all(hashes[n] == h for n,h in baseline_hashes.items() if n.startswith('constraints/'))
    timing = lambda folder: {' '.join(line.split()) for line in (folder / 'device_map/pango_video_system.dmr').read_text(errors='replace').splitlines() if re.match(r'^\s*(create_clock|create_generated_clock|set_\w+) ',line)}
    checks['mapped_timing_inventory_equal'] = timing(a.mapping) == timing(baseline)
    for index, folder in enumerate(a.software):
        result = read(folder / 'result.json')
        checks['software_' + str(index)] = result['passed'] and result['inputs_intact'] and all(sha(folder / n) == h for n,h in result['frozen_files'].items()) and all(sha(Path(p)) == h for p,h in result['origins'].items())
        checks['software_binding_' + str(index)] = all(sha(folder / 'source' / Path(n).name) == hashes[n] for n in changes)
        evidence['software_' + str(index)] = dict(path=str(folder.resolve()), result_sha256=sha(folder / 'result.json'), cases=result['cases'])
    cdc = read(a.cdc / 'result.json')
    checks['cdc'] = cdc['passed'] and cdc['snapshot_intact'] and Path(cdc['rtl_origin']).resolve() == candidate / 'source' and all(sha(a.cdc / 'source' / n) == h for n,h in cdc['source_hashes'].items())
    # Bind flat simulator copies to the selected RTL bytes, not just a path
    # recorded by their runner. These suites intentionally compile subsets.
    checks['cdc_candidate_binding'] = all(cdc['source_hashes'].get(Path(n).name) == h
        for n,h in hashes.items() if n.startswith('rtl/') and Path(n).name in cdc['source_hashes'])
    integrity = read(a.integrity / 'result.json')
    checks['mcu_integrity'] = integrity['passed'] and integrity['snapshot_intact'] and integrity['inputs_intact'] and all(sha(a.integrity / n) == h for n,h in integrity['hashes'].items()) and Path(integrity['rtl_snapshot']).resolve() == candidate / 'source'
    checks['integrity_candidate_binding'] = integrity['hashes']['mcu_readonly_client.sv'] == hashes['rtl/control/mcu_readonly_client.sv']
    host = read(a.host)
    checks['host_vector_binding'] = host['passed'] and host['companion_snapshot_intact'] and Path(host['input_directory']).resolve() == a.network.resolve() and all(sha(a.network / n) == h for n,h in host['input_sha256'].items())
    for label, path in [('cdc',a.cdc/'result.json'),('integrity',a.integrity/'result.json'),('host',a.host)]:
        evidence[label] = dict(path=str(path.resolve()), sha256=sha(path))
    log = (a.full / 'run.log').read_text()
    baseline_full = fpga/'build/full_integration_20261013/verilator_20261023_215122_863087'
    baseline_fixture = read(baseline_full/'sources.json')
    checks['baseline_frame_fixture_equal'] = all(baseline_fixture.get(n)==h for n,h in read(a.full/'sources.json').items() if n.startswith('sim/'))
    trace = read(a.cache_trace/'result.json')
    checks['cache_trace'] = trace['passed'] and trace['inputs_intact'] and len(trace['cases'])==3 and all(
        sha(a.cache_trace/n)==h for n,h in trace['source_hashes'].items()) and all(
        c['width']==1920 and c['height']==1080 and c['pixels']==2073600 for c in trace['cases'])
    evidence['cache_trace'] = dict(path=str(a.cache_trace.resolve()), result_sha256=sha(a.cache_trace/'result.json'), cases=trace['cases'])
    cycles = list(map(int,re.findall(r'FRAME_GEOMETRY job=\d+ geometry_cycles=(\d+)',log)))
    checks['full_profile'] = all(read(a.full/'result.json').get(k) for k in ['full_frame','control_test','display_test','board_manual_profile'])
    checks['frame_budget'] = len(cycles) == 3 and max(cycles)*30 <= 125000000
    checks['display_oracle'] = 'DISPLAY_CORE_PASS new=3 repeat=1 checked_pixels=8294400 failed=0 underflow=0' in log
    checks['raw_oracle'] = 'TB_VIDEO_MEMORY_CORE_PASS bytes=6220800 good=3 processed=3' in log
    native_files = ['sources.json','result.json','synthesize/pango_video_system_syn.adf','synthesize/pango_video_system.snr',
                    'device_map/pango_video_system_map.adf','device_map/pango_video_system.dmr','device_map/pango_video_system.pcf','constraint_check/constraint_check.ccr']
    report = dict(passed=all(checks.values()), candidate=str(candidate), mapping=str(a.mapping.resolve()), checks=checks,
        changed_files=changes, evidence=evidence, mapped_resources=resources, constraint_gate=constraints,
        synthesis_baseline=synthesis(baseline/'synthesize/pango_video_system.snr'),
        synthesis_candidate=synthesis(a.mapping/'synthesize/pango_video_system.snr'),
        geometry_cycles=cycles, native_sha256={n:sha(a.mapping/n) for n in native_files},
        mapped_timing_commands=len(timing(a.mapping)),
        mapped_clock_count=sum(line.startswith(('create_clock ','create_generated_clock ')) for line in timing(a.mapping)),
        full_run_log_sha256=sha(a.full/'run.log'), audit_script_sha256=sha(Path(__file__)),
        routed=False, physical_block_occupancy=None, physical_timing_signed_off=False,
        production_selected=False, whole_design_route_allowed=False, bitstream_generation_allowed=False, hardware_tested=False)
    (candidate/'handoff_evidence.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(dict(passed=report['passed'], checks=checks, mapped_resources=resources, geometry_cycles=cycles),indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
