"""Audit completed H2 evidence without launching or changing any native job.

Keep original driver/gate records intact. Publish a separate review of source
identity, consumed constraints, diagnostic deltas and all reported clock pairs.
This review is pre-route evidence, never physical timing signoff.
"""
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re

from evaluate_g_candidate import frozen_sources, read, sha
from evaluate_h2_candidate import functional_proof, constraint_adaptation
from finalize_gray_verification import timing_summary
from review_gray_candidates import inspect


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/write_cdc_owned_read_20261031'
OUT = ROOT / 'final_review_20261101'
DE_SYN = FPGA / 'build/full_integration_20261013/board_20261031_200204_931096'
DE_MAP = FPGA / 'build/full_integration_20261013/board_postsyn_20261031_201436_865573'


def text(path):
    """Decode vendor reports while preserving their original bytes for hashes."""
    return path.read_text(encoding='utf-8-sig', errors='replace')


def timing_tables(build):
    """Retain every summary row, including empty fast-corner sections."""
    report = text(build / 'synthesize/pango_video_system.snr')
    result = {}
    headings = list(re.finditer(r'^(Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\((Slow|Fast) Corner\):', report, re.M))
    for heading in headings:
        body = report[heading.end():].split('=' * 20, 1)[0]
        rows = []
        for line in body.splitlines():
            tokens = line.split()
            if len(tokens) not in (5, 6):
                continue
            try:
                slack, total, failing, endpoints = float(tokens[-4]), float(tokens[-3]), int(tokens[-2]), int(tokens[-1])
            except ValueError:
                continue
            rows.append(dict(clocks=tokens[:-4], worst_ns=slack, total_ns=total,
                             failing_endpoints=failing, endpoints=endpoints))
        result[heading.group(0).rstrip(':')] = rows
    assert len(result) == 10, 'Missing timing summary section'
    assert len(result['Setup Summary(Slow Corner)']) == 25
    assert len(result['Hold Summary(Slow Corner)']) == 13
    assert len(result['Minimum Pulse Width Summary(Slow Corner)']) == 13
    clock_block = report.split('Clock Summary:', 1)[1].split('Clock Groups:', 1)[0]
    clocks = re.findall(r'^\s*(\S+)\s+\d+\.\d+\s+\{[^}]+\}\s+(?:Declared|Generated)', clock_block, re.M)
    assert len(clocks) == 15
    return dict(clocks=clocks, tables=result, mode='single corner synthesis estimates',
                fast_corner_populated=any(v for k,v in result.items() if '(Fast Corner)' in k))


def diagnostics(build, stage):
    """Normalize only the build path, keeping net/object changes visible."""
    lines = [line.strip() for line in text(build / stage / 'run.log').splitlines()
             if re.match(r'\s*[WCE]:', line)]
    return Counter(re.sub(r'board_\d{8}_\d{6}_\d+', 'board_ID', line) for line in lines)


def diag_codes(lines):
    """Do not lose uncoded synthesis fanout warnings in a code-only count."""
    result = Counter()
    for line, count in lines.items():
        found = re.search(r'([A-Za-z]+-\d+):', line)
        code = found[1] if found else ('syn_maxfan' if 'syn_maxfan' in line else 'uncoded')
        result[code] += count
    return dict(result)


def commands(path):
    """Compare the complete executable constraint text, not just set_* lines."""
    return [line.strip() for line in text(path).splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def main():
    """Require terminal evidence before collecting an immutable final audit."""
    continuation = ROOT / 'map_continuation_20261101'
    state = read(continuation / 'state.json')
    assert state['status'] == 'MAP_COMPLETE_INDEPENDENT_REVIEW_REQUIRED'
    syn, mapping = Path(state['synthesis']), Path(state['mapping'])
    exit_record = json.loads(text(ROOT / 'map_launch_exit.json'))
    assert exit_record['returncode'] == 0
    process = json.loads(text(OUT / 'process_exit_evidence.json'))
    assert process['query_succeeded'] and not process['processes'] and not process['native_phase_lock_exists']
    assert not (FPGA / 'build/route_optimization/native_phase.lock').exists()
    for path, digest in state['bound'].items():
        assert sha(Path(path)) == digest, 'Bound evidence drift: ' + path
    manifest, functional = functional_proof(ROOT / 'H2_candidate')
    for build in (syn, mapping):
        assert frozen_sources(build) == manifest
        result = read(build / 'result.json')
        assert result['native_exit'] == 0 and not result['errors'] and result['snapshot_intact']
    mr = read(mapping / 'result.json')
    assert mr['stage'] == 'dev_map' and mr['parent_build'] == str(syn)
    assert mr['supervision']['status'] == 'COMPLETED'
    assert mr['supervision']['policy']['timeout_seconds'] == 900
    assert mr['syn_sha256'] == sha(syn / 'synthesize/pango_video_system_syn.adf')
    assert sha(mapping / 'synthesize/pango_video_system_syn.adf') == mr['syn_sha256']
    assert mr['mapped_database_sha256'] == sha(mapping / 'device_map/pango_video_system_map.adf')
    assert not any(mr[k] for k in ('placement_started', 'routed', 'bitstream_generated', 'programmed'))
    checks = inspect(syn, mapping)
    de_checks = inspect(DE_SYN, DE_MAP)
    ccr = checks['constraints']['constraint_check']
    assert ccr['errors'] == 0 and ccr['warnings'] == 0
    assert ccr['diagnostic_counts'] == {'ConstraintEditor-2002': 33}
    normalize_ccr = lambda entries: sorted(re.sub(r'board_\d{8}_\d{6}_\d+', 'board_ID', x) for x in entries)
    assert normalize_ccr(ccr['diagnostics']) == normalize_ccr(de_checks['constraints']['constraint_check']['diagnostics'])
    assert checks['constraints']['postsyn_constraint_gate']['command_count'] == 10
    scf_name = 'source/constraints/video_system/reset_fsm_postsyn.scf'
    assert (mapping/scf_name).read_bytes() == (DE_MAP/scf_name).read_bytes()
    dmr = text(mapping / 'device_map/pango_video_system.dmr')
    normalized_loaded = {' '.join(line.split()) for line in dmr.splitlines() if line.strip().startswith('set_')}
    assert all(' '.join(c.split()) in normalized_loaded for c in commands(mapping/scf_name))
    adaptation = constraint_adaptation(mapping)
    processing = commands(mapping / 'source/constraints/video_system/processing_cdc.fdc')
    assert all(' '.join(c.split()) in normalized_loaded for c in processing)
    assert not any('read_q' in c for c in processing)
    assert not any(re.search(r'result_bridge(?:\.\*|\*|[}\s])', c) for c in processing)
    for filename in ('cdc_constraint_review.json', 'bridge_cdc_review.json'):
        review = read(continuation / filename)
        assert review['passed'] and review['dmr_sha256'] == sha(mapping / 'device_map/pango_video_system.dmr')
    ram = read(continuation / 'board_ram_mapping_gate.json')
    fsm = read(ROOT / 'post_syn_review/fsm_semantics_review.json')
    assert ram['passed'] and ram['ram_count'] == 4 and fsm['passed']
    assert ram['vm_sha256'] == fsm['vm_sha256'] == sha(syn / 'synthesize/pango_video_system_syn.vm')
    assert ram['independent_fsm_review_sha256'] == sha(ROOT / 'post_syn_review/fsm_semantics_review.json')
    assert sha(mapping / 'synthesize/pango_video_system_syn.vm') == ram['vm_sha256']
    syn_old, syn_new = diagnostics(DE_SYN, 'synthesize'), diagnostics(syn, 'synthesize')
    map_old, map_new = diagnostics(DE_MAP, 'device_map'), diagnostics(mapping, 'device_map')
    old_unconstrained = Counter({k:v for k,v in syn_old.items() if 'Timing-4086' in k or 'Timing-4087' in k})
    new_unconstrained = Counter({k:v for k,v in syn_new.items() if 'Timing-4086' in k or 'Timing-4087' in k})
    assert old_unconstrained == new_unconstrained
    assert map_old == map_new
    warnings = dict(syn_DE_counts=diag_codes(syn_old), syn_H2_counts=diag_codes(syn_new),
        synthesis_added=dict(syn_new-syn_old), synthesis_removed=dict(syn_old-syn_new),
        map_counts=diag_codes(map_new), map_added=dict(map_new-map_old), map_removed=dict(map_old-map_new),
        unconstrained_port_diagnostics_identical=True, unconstrained_diagnostics=dict(new_unconstrained),
        limitation='Counts include repeated synthesis passes; renamed internal nets are not necessarily new physical risks.')
    (OUT/'diagnostic_comparison.json').write_text(json.dumps(warnings,indent=2),encoding='utf-8')
    timings = {name:dict(summary=timing_summary(build), **timing_tables(build))
               for name,build in (('DE',DE_SYN), ('H2',syn))}
    assert all(v > 0 for v in timings['H2']['summary']['estimated_setup_ns'].values())
    assert not timings['H2']['fast_corner_populated']
    assert not any(r['failing_endpoints'] for r in timings['H2']['tables']['Setup Summary(Slow Corner)'])
    package = FPGA / 'release/packages/gray_DE_portable_20261031.zip'
    assert sha(package) == 'faa660291636078e76e18fb3cd152cf11495793627a2bbd18cc8b5e8bbf49b83'
    de_manifest = frozen_sources(FPGA / 'build/DE_optimization_20261031/candidate')
    hardware = [n for n in de_manifest if n.startswith(('rtl/', 'constraints/', 'ip/'))]
    live_differences = [n for n in hardware if not (FPGA/n).exists() or sha(FPGA/n) != de_manifest[n]]
    resources = checks['mapping_resources']
    delta = {k:v-de_checks['mapping_resources'][k] for k,v in resources.items()}
    evidence = [syn/'result.json',mapping/'result.json',mapping/'sources.json',
        syn/'synthesize/pango_video_system_syn.vm',syn/'synthesize/pango_video_system_syn.adf',
        syn/'synthesize/pango_video_system.snr',mapping/'device_map/pango_video_system_map.adf',
        mapping/'device_map/pango_video_system.dmr',mapping/'constraint_check/constraint_check.ccr',
        mapping/'native_monitor.jsonl',ROOT/'map_launch_exit.json',continuation/'review.json',
        continuation/'board_ram_mapping_gate.json',continuation/'bridge_cdc_review.json',
        continuation/'cdc_constraint_review.json',OUT/'diagnostic_comparison.json',
        OUT/'process_exit_evidence.json',Path(__file__)]
    report = dict(status='H2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE',
        checked_at=datetime.now().astimezone().isoformat(), source_count=327,
        candidate=str(ROOT/'H2_candidate'), synthesis=str(syn), mapping=str(mapping),
        candidate_sha256=sha(ROOT/'H2_candidate/sources.json'),functional=functional,
        bound_evidence=state['bound'],evidence_sha256={str(p):sha(p) for p in evidence},
        terminal=dict(exit=exit_record,native=mr['supervision'],process_evidence=process),
        resources=resources,DE_resources=de_checks['mapping_resources'],delta_vs_DE=delta,
        constraints=dict(ccr_errors=0,ccr_existing_share_pin=33,ccr_new=0,
            consumed_postsyn_scf=10,postsyn_scf_identical_to_DE=True,
            processing_commands_loaded=len(processing),adaptation=adaptation,
            camera_first_hop_verified=True,no_new_broad_exceptions=True),
        timing=timings,diagnostics=warnings,
        ordinary_RAM_timing='Write data/address/enable, read address/enable and RAM-to-DDR consumers retain ordinary constraints; physical setup/hold unverified.',
        source_isolation=dict(live_hardware_checked=len(hardware),live_differences_vs_DE=live_differences,
            DE_package_sha256=sha(package)),
        limitations=['No placement/routing or real min/max STA; all timing here is synthesis estimation.',
            'Existing 53 input and 94 output unconstrained-port diagnostics remain; external interface timing is not signed off.',
            'DDR hold violations remain; post-SYN reset SCF consumption does not constitute routed timing proof.',
            'New synthesis syn_maxfan net diagnostics retained for review; no guarantee global fanout or route convergence improved.',
            'G is an independent candidate, not combined or validated with H2.'],
        physical_signoff=False,promoted=False,routing_started=False,bitstream_generated=False)
    (OUT/'final_review.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(dict(status=report['status'],resources=resources,delta=delta,
        warning_counts=warnings['syn_H2_counts'],live_differences=live_differences,
        evidence=str(OUT/'final_review.json')),indent=2))


if __name__ == '__main__':
    main()
