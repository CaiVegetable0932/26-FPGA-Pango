"""Independently review completed GH2 SYN/MAP without starting native work.

Default is read-only. --write exclusively creates a new final-review directory
after all checks pass. Original driver, netlist gates and parent results remain
unchanged. This is pre-route validation, never routed timing or board signoff.
"""
import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import sys

from evaluate_g_candidate import frozen_sources, read, sha
from evaluate_h2_candidate import constraint_adaptation
from finalize_h2_validation import timing_tables, diagnostics, diag_codes, commands, text
from finalize_gray_verification import timing_summary
from review_gh2_functional import functional_proof
from review_gh2_netlist import topology_inspector
from audit_h2_fsm_semantics import audit as audit_fsm
from review_g_netlist import inspect_syn, compare
from review_gray_candidates import inspect
from constraint_report import read_constraint_report


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA/'build/gh2_integration_20261101'
OUT = ROOT/'final_review_20261101'
NATIVE = ROOT/'native'
PACKAGE_SHA = 'faa660291636078e76e18fb3cd152cf11495793627a2bbd18cc8b5e8bbf49b83'


def require(condition, reason):
    """Keep new audit gates active even if Python optimization was requested."""
    if not condition:
        raise ValueError(reason)


def hashes_intact(bindings):
    """Require every bound file, including the original auditor scripts."""
    for name,digest in bindings.items():
        require(sha(Path(name)) == digest, 'Bound file changed: '+name)


def visible_terminal_processes(tracked_ids, ended_at):
    """Inspect current visible CIM identities; distinguish a reused PID by time.

The exit files and native results are required independently. An empty process
list never substitutes for those artifacts, and inaccessible CIM fails closed.
"""
    identifiers = ','.join(str(int(n)) for n in sorted(set(tracked_ids)))
    command = r"""$ErrorActionPreference='Stop';
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);
$self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID);
if(-not $self.CommandLine -or -not $self.ExecutablePath){throw 'CIM identity not visible'};
$ids=@(__IDS__);
$all=@(Get-CimInstance Win32_Process);
$rows=@($all | Where-Object {$_.ProcessId -in $ids -or $_.Name -match '^(pds|pds_shell|pango_design_suite|synplify_pro|synthesis|map|ads|pds_gui)\.exe$' -or $_.ExecutablePath -like 'E:\PDS_Pangu\*'} | ForEach-Object {
[ordered]@{pid=$_.ProcessId;parent_pid=$_.ParentProcessId;name=$_.Name;created_at=$_.CreationDate.ToString('o');executable=$_.ExecutablePath;command=$_.CommandLine;
native=($_.Name -match '^(pds|pds_shell|pango_design_suite|synplify_pro|synthesis|map|ads|pds_gui)\.exe$' -or $_.ExecutablePath -like 'E:\PDS_Pangu\*')}});
[ordered]@{checked_at=(Get-Date -Format o);query_succeeded=$true;query_self_pid=$PID;processes=$rows} | ConvertTo-Json -Depth 5
""".replace('__IDS__', identifiers)
    result = subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',command],
        capture_output=True,text=True,encoding='utf-8-sig',errors='strict',timeout=30)
    require(result.returncode == 0, 'Visible CIM query failed: '+result.stderr.strip()[:2000])
    record = json.loads(result.stdout)
    require(record['query_succeeded'], 'CIM query not successful')
    ended = datetime.fromisoformat(ended_at)
    for process in record['processes']:
        require(not process['native'], 'PDS/native process still present')
        require(process['command'] and process['executable'], 'Tracked PID identity is not visible')
        require(datetime.fromisoformat(process['created_at']) > ended,
                'A tracked launch/driver/native PID has not exited')
        process['pid_reused_after_recorded_exit'] = True
    record['native_phase_lock_exists'] = (FPGA/'build/route_optimization/native_phase.lock').exists()
    require(not record['native_phase_lock_exists'], 'Native phase lock remains')
    return record


def netlist_proof(syn, manifest, baseline_syn, baseline_manifest):
    """Recompute both structures on one actual GH2 VM, then verify saved gates."""
    out = NATIVE/'netlist_review'
    vm = syn/'synthesize/pango_video_system_syn.vm'
    vm_sha = sha(vm)
    gate = read(out/'review.json')
    require(gate['passed'] and gate['status']=='GH2_ACTUAL_BOARD_RAM_FSM_CE_VERIFIED', 'Combined VM gate incomplete')
    hashes_intact(gate['scripts_sha256'])
    require(gate['vm_sha256']==vm_sha, 'Combined gate is not for actual GH2 VM')
    for key,filename in (('ram_gate_sha256','board_ram_mapping_gate.json'),
                         ('fsm_review_sha256','fsm_semantics.json'),('ce_review_sha256','ce_review.json')):
        require(gate[key]==sha(out/filename), 'Saved netlist audit changed: '+filename)
    actual_ram = topology_inspector()(vm)
    saved_ram = read(out/'board_ram_mapping_gate.json')
    require(all(saved_ram[k]==v for k,v in actual_ram.items()), 'Actual RAM topology differs from saved proof')
    actual_fsm = audit_fsm(vm, guarded_board=True)
    require(actual_fsm==read(out/'fsm_semantics.json'), 'Actual FSM differs from saved proof')
    require(actual_fsm['passed'] and actual_fsm['parent_predicates']['passed'], 'FSM ownership incomplete')
    require(saved_ram['independent_fsm_review_sha256']==sha(out/'fsm_semantics.json'), 'RAM/FSM binding mismatch')
    actual_de = inspect_syn(baseline_syn,baseline_manifest)
    actual_ce = inspect_syn(syn,manifest)
    comparison = compare(actual_de,actual_ce)
    saved_ce = read(out/'ce_review.json')
    require(saved_ce['baseline']==actual_de and saved_ce['current']==actual_ce and saved_ce['comparison']==comparison,
            'Actual CE sinks/branches differ from saved proof')
    require(comparison['retained_payload_metadata_coverage_equal'] and comparison['four_enables_replication_visible'],
            'Combined VM lacks intended CE split or retained payload coverage')
    require(actual_ce['vm_sha256']==actual_fsm['vm_sha256']==saved_ram['vm_sha256']==vm_sha,
            'RAM, FSM and CE evidence must reference the same GH2 VM')
    require((NATIVE/'board_ram_mapping_gate.json').read_bytes()==(out/'board_ram_mapping_gate.json').read_bytes(),
            'Copied bridge CDC gate differs')
    return dict(vm_sha256=vm_sha,ram=actual_ram,fsm=actual_fsm,ce=actual_ce,ce_comparison=comparison,
                independently_recomputed=True,physical_signoff=False)


def constraint_proof(syn, mapping, baseline_syn, baseline_map, checks, baseline_checks):
    """Recheck exact constraints, unchanged CDC commands and real DMR loading."""
    normalize = lambda entries: sorted(re.sub(r'board_(?:postsyn_)?\d{8}_\d{6}_\d+', 'board_ID', x) for x in entries)
    ccrs = []
    for build,baseline in ((syn,baseline_syn),(mapping,baseline_map)):
        current = read_constraint_report(build/'constraint_check/constraint_check.ccr')
        old = read_constraint_report(baseline/'constraint_check/constraint_check.ccr')
        require(current['summary_valid'] and current['errors']==0 and current['warnings']==0 and
                current['diagnostic_counts']=={'ConstraintEditor-2002':33}, 'Unexpected CCR diagnostic set')
        require(normalize(current['diagnostics'])==normalize(old['diagnostics']), 'CCR share-pin objects changed')
        ccrs.append(current)
    gate = checks['constraints']['postsyn_constraint_gate']
    require(gate['consumed'] and gate['command_count']==10, 'Ten post-SYN SCF commands not consumed')
    scf = 'source/constraints/video_system/reset_fsm_postsyn.scf'
    require((mapping/scf).read_bytes()==(baseline_map/scf).read_bytes(), 'Post-SYN SCF differs from DE')
    dmr = text(mapping/'device_map/pango_video_system.dmr')
    loaded = {' '.join(line.split()) for line in dmr.splitlines() if line.strip().startswith('set_')}
    processing = commands(mapping/'source/constraints/video_system/processing_cdc.fdc')
    adaptation = constraint_adaptation(mapping)
    require(all(' '.join(c.split()) in loaded for c in commands(mapping/scf)+processing), 'SCF/processing commands missing from DMR')
    require(not any('read_q' in c or re.search(r'result_bridge(?:\.\*|\*|[}\s])',c) for c in processing),
            'Obsolete read_q or broad bridge exception present')
    # The source hash checks cover every other CDC file. Recompute the camera
    # first-hop scope and verify the native auditor's original hashed reports.
    fdc = mapping/'source/constraints/video_system/clocks_cdc.fdc'
    require(fdc.read_bytes()==(baseline_map/'source/constraints/video_system/clocks_cdc.fdc').read_bytes(),
            'Camera/clock CDC changed from DE')
    camera = [c for c in commands(fdc) if 'camera_input.paused_meta' in c]
    require(len(camera)==2 and all(' '.join(c.split()) in loaded for c in camera), 'Camera first-hop constraints missing')
    require(not any('paused_sync' in c for c in camera), 'Camera downstream exception broadened')
    for filename in ('cdc_constraint_review.json','bridge_cdc_review.json'):
        report = read(NATIVE/filename)
        require(report['passed'] and report['dmr_sha256']==sha(mapping/'device_map/pango_video_system.dmr'),
                'Native CDC review does not bind this MAP: '+filename)
    bridge = read(NATIVE/'bridge_cdc_review.json')
    require(bridge['board_ram_gate_sha256']==sha(NATIVE/'board_ram_mapping_gate.json'), 'Bridge CDC/VM gate binding changed')
    require(checks['constraints']['no_known_unmatched_timing_paths'], 'Known unmatched timing constraint')
    return dict(ccr=ccrs,consumed_postsyn_scf=10,postsyn_scf_identical_to_DE=True,
        processing_commands_loaded=len(processing),adaptation=adaptation,camera_first_hop_commands=camera,
        no_new_broad_exceptions=True,all_other_constraint_files_match_reviewed_parents=True,
        ordinary_RAM_address_CE_and_DDR_consumer_setup_hold_retained=True,physical_signoff=False)


def diagnostic_proof(syn, mapping, baseline_syn, baseline_map):
    """Retain new net-level SYN warnings while rejecting changed MAP diagnostics."""
    old_syn,new_syn=diagnostics(baseline_syn,'synthesize'),diagnostics(syn,'synthesize')
    old_map,new_map=diagnostics(baseline_map,'device_map'),diagnostics(mapping,'device_map')
    unconstrained=lambda records:Counter({k:v for k,v in records.items() if 'Timing-4086' in k or 'Timing-4087' in k})
    old_ports,new_ports=unconstrained(old_syn),unconstrained(new_syn)
    require(old_ports==new_ports, 'Unconstrained-port object/diagnostic set changed')
    ports=diag_codes(new_ports)
    require(ports=={'Timing-4086':53,'Timing-4087':94}, 'Unexpected input/output unconstrained counts')
    require(old_map==new_map, 'New or changed MAP warnings require manual review')
    return dict(syn_DE_counts=diag_codes(old_syn),syn_GH2_counts=diag_codes(new_syn),
        synthesis_added=dict(new_syn-old_syn),synthesis_removed=dict(old_syn-new_syn),
        map_counts=diag_codes(new_map),map_added=dict(new_map-old_map),map_removed=dict(old_map-new_map),
        unconstrained_port_diagnostics_identical=True,unconstrained_diagnostics=dict(new_ports),
        limitation='SYN counts include repeated passes; renamed nets do not by themselves establish a new physical risk.')


def collect(launch_started, launch_exit):
    """Read exact dynamic pointers; missing or active results never look complete."""
    require(not sys.flags.optimize, 'Reused auditors require Python assertions')
    state=read(NATIVE/'state.json')
    require(state['status']=='SYN_MAP_COMPLETE_INDEPENDENT_REVIEW_REQUIRED', 'GH2 SYN/MAP is not complete')
    started=json.loads(text(launch_started));ended=json.loads(text(launch_exit))
    require(ended['returncode']==0 and ended['wrapper_pid']==started['wrapper_pid'], 'Launch did not exit cleanly')
    require(started['mode']=='SYN45_GATE_MAP15_ONLY', 'Unexpected launcher identity')
    launcher=ROOT/'launch_native.ps1'
    require(text(launcher).count('& python -X utf8 -B fpga/scripts/evaluate_gh2_candidate.py --run')==1,
            'Expected one bounded native driver invocation in launcher')
    require(datetime.fromisoformat(ended['ended_at'])>datetime.fromisoformat(started['started_at']), 'Invalid launch chronology')
    syn,mapping=Path(state['synthesis']),Path(state['mapping'])
    require(Path(state['candidate']).resolve()==(ROOT/'candidate').resolve(), 'Native candidate pointer mismatch')
    require(Path(state['review']).resolve()==(NATIVE/'review.json').resolve(), 'Native review pointer mismatch')
    require(Path(state['netlist_review']).resolve()==(NATIVE/'netlist_review/review.json').resolve(), 'VM review pointer mismatch')
    manifest,functional=functional_proof(ROOT/'candidate')
    require(state['functional']==functional and state['sources_sha256']==functional['sources_sha256'], 'Native/function source binding changed')
    claim=read(ROOT/'native_dispatch_claim.json')
    require(claim['driver_pid']==state['driver_pid'] and claim['sources_sha256']==functional['sources_sha256'] and
            claim['functional_sha256']==functional['sha256'], 'Dispatch claim identity changed')
    hashes_intact(read(NATIVE/'scripts.json'))
    require(sha(NATIVE/'driver.py')==sha(FPGA/'scripts/evaluate_gh2_candidate.py'), 'Frozen native driver changed')
    hashes_intact(state['netlist_gate_sha256'])
    require(set(state['completed_artifacts_sha256'])=={'synthesis','mapping'}, 'Incomplete native artifact bindings')
    for bindings in state['completed_artifacts_sha256'].values():
        hashes_intact(bindings)
    results={}
    for name,build,stage,budget in (('synthesis',syn,'synthesize',2700),('mapping',mapping,'dev_map',900)):
        require(frozen_sources(build)==manifest, '327 source mismatch: '+name)
        result=read(build/'result.json');results[name]=result
        require(result['native_exit']==0 and not result['errors'] and result['snapshot_intact'], 'Native stage failed: '+name)
        require(result['stage']==stage and result['supervision']['status']=='COMPLETED' and
                result['supervision']['returncode']==0 and result['supervision']['policy']['timeout_seconds']==budget,
                'Native stage identity/budget mismatch: '+name)
        require(state[name+'_wrapper_exit']==0 and state[name+'_result_sha256']==sha(build/'result.json'), 'Wrapper/result drift: '+name)
        require(not any(result.get(k,False) for k in ('placement_started','routed','bitstream_generated','programmed')),
                'Unexpected physical/programming work')
    mr=results['mapping']
    require(mr['parent_build']==str(syn) and mr['syn_intact'], 'MAP not derived from precise SYN')
    require(mr['syn_sha256']==sha(syn/'synthesize/pango_video_system_syn.adf')==sha(mapping/'synthesize/pango_video_system_syn.adf'), 'SYN database identity mismatch')
    require(mr['mapped_database_sha256']==sha(mapping/'device_map/pango_video_system_map.adf'), 'MAP database drift')
    require(sha(syn/'synthesize/pango_video_system_syn.vm')==sha(mapping/'synthesize/pango_video_system_syn.vm'), 'MAP inherited another VM')
    process=visible_terminal_processes([started['wrapper_pid'],state['driver_pid'],
        results['synthesis']['supervision']['pid'],mr['supervision']['pid']],ended['ended_at'])
    de=FPGA/'build/DE_optimization_20261031';ds=read(de/'native/state.json')
    baseline_syn,baseline_map=Path(ds['synthesis']),Path(ds['mapping'])
    baseline_manifest=frozen_sources(de/'candidate')
    for name,build in (('synthesis',baseline_syn),('mapping',baseline_map)):
        require(frozen_sources(build)==baseline_manifest and sha(build/'result.json')==ds[name+'_result_sha256'], 'DE baseline drift')
    checks=inspect(syn,mapping);baseline_checks=inspect(baseline_syn,baseline_map)
    require(baseline_checks['mapping_resources']=={'LUT':37592,'FF':41960,'APM':154,'DRM':71.5,'Distributed RAM':1275}, 'Unexpected DE resource baseline')
    native_review=read(NATIVE/'review.json')
    require(native_review['status']=='GH2_SYN_MAP_COMPLETE_INDEPENDENT_REVIEW_REQUIRED' and
            native_review['mapping_resources']==checks['mapping_resources']==state['resources'], 'Native review resources disagree')
    require(native_review['constraints']==checks['constraints'], 'Native constraint record differs from actual MAP')
    structures=netlist_proof(syn,manifest,baseline_syn,baseline_manifest)
    constraints=constraint_proof(syn,mapping,baseline_syn,baseline_map,checks,baseline_checks)
    warnings=diagnostic_proof(syn,mapping,baseline_syn,baseline_map)
    timings={label:dict(summary=timing_summary(build),**timing_tables(build)) for label,build in (('DE',baseline_syn),('GH2',syn))}
    require(timings['DE']['clocks']==timings['GH2']['clocks'], 'Clock definitions changed')
    for section,rows in timings['DE']['tables'].items():
        require(sorted(r['clocks'] for r in rows)==sorted(r['clocks'] for r in timings['GH2']['tables'][section]), 'Clock-pair coverage changed: '+section)
    estimates=timings['GH2']['summary']['estimated_setup_ns'];old_estimates=timings['DE']['summary']['estimated_setup_ns']
    require(set(estimates)==set(old_estimates), 'Estimated clock set changed')
    require(all(v>0 for v in estimates.values()) and not any(r['failing_endpoints'] for r in timings['GH2']['tables']['Setup Summary(Slow Corner)']), 'Estimated setup needs independent review')
    require(not timings['GH2']['fast_corner_populated'], 'Unexpected synthesis timing corner model')
    require(native_review['timing']==timings['GH2']['summary'], 'Native timing summary differs')
    hardware=[n for n in baseline_manifest if n.startswith(('rtl/','constraints/','ip/'))]
    live_differences=[n for n in hardware if not (FPGA/n).is_file() or sha(FPGA/n)!=baseline_manifest[n]]
    require(len(hardware)==310 and not live_differences, 'Live hardware differs from frozen DE')
    package=FPGA/'release/packages/gray_DE_portable_20261031.zip'
    require(sha(package)==PACKAGE_SHA, 'External DE package changed')
    evidence=[NATIVE/'state.json',NATIVE/'review.json',NATIVE/'scripts.json',NATIVE/'driver.py',
        ROOT/'native_dispatch_claim.json',launch_started,launch_exit,launcher,Path(functional['path']),
        NATIVE/'cdc_constraint_review.json',NATIVE/'bridge_cdc_review.json',NATIVE/'board_ram_mapping_gate.json',
        Path(__file__),FPGA/'scripts/finalize_h2_validation.py',syn/'synthesize/run.log',mapping/'device_map/run.log']
    bound={str(p):sha(p) for p in evidence}
    bound.update(state['netlist_gate_sha256'])
    for bindings in state['completed_artifacts_sha256'].values():bound.update(bindings)
    resources=checks['mapping_resources']
    return dict(status='GH2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE',passed=True,
        checked_at=datetime.now().astimezone().isoformat(),source_count=327,candidate=str(ROOT/'candidate'),
        synthesis=str(syn),mapping=str(mapping),candidate_sha256=functional['sources_sha256'],functional=functional,
        evidence_sha256=bound,terminal=dict(start=started,exit=ended,current_process_evidence=process,
            native={name:result['supervision'] for name,result in results.items()}),
        resources=resources,DE_resources=baseline_checks['mapping_resources'],
        delta_vs_DE={k:v-baseline_checks['mapping_resources'][k] for k,v in resources.items()},
        actual_combined_netlist=structures,constraints=constraints,timing=timings,
        estimated_setup_delta_vs_DE={k:v-old_estimates[k] for k,v in estimates.items()},diagnostics=warnings,
        source_isolation=dict(live_hardware_checked=310,live_differences_vs_DE=live_differences,DE_package_sha256=PACKAGE_SHA),
        limitations=['No PnR/routed database or real min/max STA; synthesis estimates are not physical signoff.',
            'Existing 53 input and 94 output unconstrained diagnostics remain; external timing is not signed off.',
            'All reported hold/removal paths and clock-pair tables are retained, including DDR/OSERDES/DQS risk.',
            'CE branch locality and SDP inference are actual combined SYN evidence; route convergence benefit remains unproven.',
            'Parent leaf/consumer tests were reused by exact dependency identity; the combined full-video test was freshly run.'],
        physical_signoff=False,promoted=False,routing_started=False,bitstream_generated=False)


def main():
    """Default reads only; publish once only after all actual evidence passes."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write',action='store_true')
    parser.add_argument('--launch-started',type=Path,default=ROOT/'native_launch_started.json')
    parser.add_argument('--launch-exit',type=Path,default=ROOT/'native_launch_exit.json')
    args=parser.parse_args()
    if args.write:require(not OUT.exists(), 'Final-review directory already exists; inspect it instead of replacing')
    result=collect(args.launch_started.resolve(),args.launch_exit.resolve())
    if args.write:
        OUT.mkdir(exist_ok=False)
        (OUT/'final_review.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(dict(status=result['status'],resources=result['resources'],delta_vs_DE=result['delta_vs_DE'],
        warning_counts=result['diagnostics']['syn_GH2_counts'],physical_signoff=False,
        written_to=str(OUT/'final_review.json') if args.write else None),indent=2))


if __name__=='__main__':
    main()
