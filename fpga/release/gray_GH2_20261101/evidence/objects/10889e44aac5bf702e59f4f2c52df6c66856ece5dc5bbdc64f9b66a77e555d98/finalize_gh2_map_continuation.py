"""Independently audit the one-use GH2 MAP continuation; never launch PDS.

Reuse existing constraint/diagnostic/timing auditors on the new continuation,
and recompute the actual GH2 RAM/FSM/CE structure with the separately reviewed
parent-guard parser. Old stopped states/reports and bound scripts are untouched.
Default is read-only; --write creates a new final-review directory once.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import sys

import finalize_gh2_validation as base
from evaluate_g_candidate import frozen_sources, read, sha
from evaluate_gh2_map_only import (FPGA,ROOT,OUT as CONTINUATION,CLAIM,AUDIT,MODE,SUCCESS,
    DE_RESOURCES,require,hashes_intact,immutable_inputs,native_result,verify_map_identity)
from finalize_gray_verification import timing_summary
from finalize_h2_validation import timing_tables,text
from review_gh2_netlist import topology_inspector
from review_g_netlist import inspect_syn,compare
from review_gray_candidates import inspect


OUT = ROOT/'final_review_20261101'
PACKAGE_SHA = 'faa660291636078e76e18fb3cd152cf11495793627a2bbd18cc8b5e8bbf49b83'


def recompute_structures(syn, manifest, baseline_syn, baseline_manifest):
    """Independently recompute all three actual-VM proofs without writing them."""
    from audit_gh2_fsm_semantics import audit as audit_fsm
    vm = syn/'synthesize/pango_video_system_syn.vm'
    ram = topology_inspector()(vm); saved_ram=read(AUDIT/'board_ram_mapping_gate.json')
    require(all(saved_ram[k]==v for k,v in ram.items()), 'Actual RAM topology differs from saved gate')
    fsm=audit_fsm(vm,guarded_board=True)
    require(fsm==read(AUDIT/'fsm_semantics.json') and fsm['passed'] and fsm['parent_predicates']['passed'],
            'Actual combined FSM/parent predicate proof changed')
    current=inspect_syn(syn,manifest); baseline=inspect_syn(baseline_syn,baseline_manifest)
    comparison=compare(baseline,current);saved_ce=read(AUDIT/'ce_review.json')
    require(saved_ce['baseline']==baseline and saved_ce['current']==current and
            saved_ce['comparison']==comparison, 'Actual retained FF/CE branch proof changed')
    require(comparison['retained_payload_metadata_coverage_equal'] and comparison['four_enables_replication_visible'],
            'Actual CE split/coverage proof incomplete')
    require(current['vm_sha256']==fsm['vm_sha256']==saved_ram['vm_sha256']==sha(vm),
            'Structural proofs reference different VMs')
    require(saved_ram['independent_fsm_review_sha256']==sha(AUDIT/'fsm_semantics.json'), 'RAM/FSM binding differs')
    require((CONTINUATION/'board_ram_mapping_gate.json').read_bytes()==(AUDIT/'board_ram_mapping_gate.json').read_bytes(),
            'Continuation copied RAM gate changed')
    return dict(vm_sha256=sha(vm),ram=ram,fsm=fsm,ce=current,ce_comparison=comparison,
                independently_recomputed=True,physical_signoff=False)


def collect(launch_started,launch_exit):
    """Require terminal native/launcher evidence, source identities and real MAP."""
    require(not sys.flags.optimize, 'Reused auditors require Python assertions')
    state=read(CONTINUATION/'state.json')
    require(state['status']==SUCCESS and state['mode']==MODE, 'GH2 MAP continuation is not complete')
    started=json.loads(text(launch_started));ended=json.loads(text(launch_exit))
    require(started['mode']==MODE and ended['returncode']==0 and ended['wrapper_pid']==started['wrapper_pid'],
            'MAP launcher identity or exit differs')
    require(datetime.fromisoformat(ended['ended_at'])>datetime.fromisoformat(started['started_at']),
            'Invalid MAP launcher chronology')
    launcher=ROOT/'launch_map_continuation_20261101.ps1'
    require(text(launcher).count('& python -X utf8 -B fpga/scripts/evaluate_gh2_map_only.py --run')==1,
            'Unexpected continuation launcher command')
    data=immutable_inputs();syn=data['synthesis'];mapping=Path(state['mapping'])
    require(Path(state['candidate']).resolve()==data['candidate'].resolve() and
            Path(state['synthesis']).resolve()==syn.resolve() and
            Path(state['review']).resolve()==(CONTINUATION/'review.json').resolve() and
            Path(state['netlist_review']).resolve()==(AUDIT/'review.json').resolve(), 'Continuation pointers differ')
    require(state['functional']==data['functional'] and state['sources_sha256']==data['functional']['sources_sha256'] and
            state['bound']==data['bound'], 'Continuation evidence no longer matches immutable input')
    hashes_intact(state['bound']);hashes_intact(state['scripts']);hashes_intact(state['mapping_artifacts_sha256'])
    require(state['scripts']==read(CONTINUATION/'scripts.json') and
            sha(CONTINUATION/'driver.py')==sha(FPGA/'scripts/evaluate_gh2_map_only.py'), 'Frozen continuation driver changed')
    claim=read(CLAIM)
    require(claim['mode']==MODE and claim['driver_pid']==state['driver_pid'] and
            claim['sources_sha256']==state['sources_sha256'] and
            claim['functional_sha256']==data['functional']['sha256'] and
            claim['netlist_review_sha256']==sha(AUDIT/'review.json') and
            Path(claim['synthesis']).resolve()==syn.resolve(), 'One-use continuation claim differs')
    sr=native_result(syn,'synthesize',2700);mr=verify_map_identity(syn,mapping,data['manifest'])
    require(state['mapping_wrapper_exit']==0 and state['mapping_result_sha256']==sha(mapping/'result.json'),
            'MAP wrapper/result evidence differs')
    # SYN may have finished hours before MAP. Compare any reused old PID to
    # its own recorded exit, rather than incorrectly treating a process born
    # between SYN and MAP as the original synthesis process.
    old_exit=json.loads(text(ROOT/'native_launch_exit.json'))
    old_state=read(ROOT/'native/state.json')
    process=dict(mapping=base.visible_terminal_processes(
        [started['wrapper_pid'],state['driver_pid'],mr['supervision']['pid']],ended['ended_at']),
        synthesis=base.visible_terminal_processes(
            [old_exit['wrapper_pid'],old_state['driver_pid'],sr['supervision']['pid']],old_exit['ended_at']))
    de=FPGA/'build/DE_optimization_20261031';ds=read(de/'native/state.json')
    bs,bm=Path(ds['synthesis']),Path(ds['mapping']);dm=frozen_sources(de/'candidate')
    require(ds['status']=='FUNCTIONAL_SYN_MAP_VERIFIED_PRE_ROUTE', 'DE comparison state changed')
    for name,build in (('synthesis',bs),('mapping',bm)):
        require(frozen_sources(build)==dm and sha(build/'result.json')==ds[name+'_result_sha256'], 'DE comparison drift')
    checks=inspect(syn,mapping);baseline=inspect(bs,bm);native=read(CONTINUATION/'review.json')
    require(baseline['mapping_resources']==DE_RESOURCES, 'DE resource baseline differs')
    require(native['status']==SUCCESS and native['mapping_resources']==checks['mapping_resources']==state['resources'] and
            native['constraints']==checks['constraints'], 'Native review does not match actual MAP')
    structures=recompute_structures(syn,data['manifest'],bs,dm)
    # The existing independent checker reads its report directory through this
    # module variable. Redirect only this process-local lookup, then restore it;
    # no old source file, saved gate or stopped native state is edited.
    prior_native=base.NATIVE
    try:
        base.NATIVE=CONTINUATION
        constraints=base.constraint_proof(syn,mapping,bs,bm,checks,baseline)
    finally:
        base.NATIVE=prior_native
    diagnostics=base.diagnostic_proof(syn,mapping,bs,bm)
    timings={label:dict(summary=timing_summary(build),**timing_tables(build)) for label,build in (('DE',bs),('GH2',syn))}
    require(timings['DE']['clocks']==timings['GH2']['clocks'], 'Clock definitions changed')
    for section,rows in timings['DE']['tables'].items():
        require(sorted(r['clocks'] for r in rows)==sorted(r['clocks'] for r in timings['GH2']['tables'][section]),
                'Clock-pair coverage changed: '+section)
    estimates=timings['GH2']['summary']['estimated_setup_ns'];old_estimates=timings['DE']['summary']['estimated_setup_ns']
    require(set(estimates)==set(old_estimates), 'Estimated clock set differs')
    require(all(v>0 for v in estimates.values()) and not any(
        r['failing_endpoints'] for r in timings['GH2']['tables']['Setup Summary(Slow Corner)']),
        'Estimated setup requires independent review')
    require(not timings['GH2']['fast_corner_populated'], 'Unexpected synthesis corner model')
    require(native['timing']==timings['GH2']['summary'], 'Native estimated timing differs')
    hardware=[n for n in dm if n.startswith(('rtl/','constraints/','ip/'))]
    differences=[n for n in hardware if not (FPGA/n).is_file() or sha(FPGA/n)!=dm[n]]
    require(len(hardware)==310 and not differences, 'Live DE hardware changed')
    package=FPGA/'release/packages/gray_DE_portable_20261031.zip'
    require(sha(package)==PACKAGE_SHA, 'External DE package changed')
    evidence=[CONTINUATION/'state.json',CONTINUATION/'review.json',CONTINUATION/'scripts.json',
        CONTINUATION/'driver.py',CONTINUATION/'command.json',CONTINUATION/'terminal_process.json',
        CONTINUATION/'process_preflight.json',CONTINUATION/'board_ram_mapping_gate.json',
        CONTINUATION/'cdc_constraint_review.json',CONTINUATION/'bridge_cdc_review.json',
        CLAIM,launch_started,launch_exit,launcher,Path(__file__),syn/'synthesize/run.log',mapping/'device_map/run.log']
    bound={str(p):sha(p) for p in evidence};bound.update(state['bound']);bound.update(state['scripts'])
    bound.update(state['mapping_artifacts_sha256'])
    resources=checks['mapping_resources']
    return dict(status='GH2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE',passed=True,
        checked_at=datetime.now().astimezone().isoformat(),source_count=327,candidate=str(data['candidate']),
        synthesis=str(syn),mapping=str(mapping),candidate_sha256=data['functional']['sources_sha256'],
        functional=data['functional'],evidence_sha256=bound,
        terminal=dict(start=started,exit=ended,current_process_evidence=process,
            native=dict(synthesis=sr['supervision'],mapping=mr['supervision'])),
        resources=resources,DE_resources=DE_RESOURCES,delta_vs_DE={k:v-DE_RESOURCES[k] for k,v in resources.items()},
        actual_combined_netlist=structures,constraints=constraints,timing=timings,diagnostics=diagnostics,
        estimated_setup_delta_vs_DE={k:v-old_estimates[k] for k,v in estimates.items()},
        source_isolation=dict(live_hardware_checked=310,live_differences_vs_DE=differences,DE_package_sha256=PACKAGE_SHA),
        original_stopped_SYN_gate_preserved=True,
        limitations=['No PnR/routed database or real min/max STA; all timing is synthesis estimation.',
            'Existing 53 input and 94 output unconstrained-port diagnostics remain; external timing is not signed off.',
            'All hold/removal tables remain, including DDR same-domain/OSERDES/DQS gate risk.',
            'Actual CE locality and SDP inference do not prove improved physical convergence.',
            'Fresh combined 1080p proof and exactly reused parent unit/consumer proofs retain their stated scopes.'],
        physical_signoff=False,promoted=False,routing_started=False,bitstream_generated=False)


def main():
    """Only --write publishes an exclusive final record after every audit passes."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true')
    parser.add_argument('--launch-started',type=Path,default=ROOT/'map_launch_started.json')
    parser.add_argument('--launch-exit',type=Path,default=ROOT/'map_launch_exit.json')
    args=parser.parse_args()
    if args.write:
        require(not OUT.exists(), 'Final review already exists; do not replace it')
    result=collect(args.launch_started.resolve(),args.launch_exit.resolve())
    if args.write:
        OUT.mkdir(exist_ok=False)
        (OUT/'final_review.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(dict(status=result['status'],resources=result['resources'],delta_vs_DE=result['delta_vs_DE'],
        warning_counts=result['diagnostics']['syn_GH2_counts'],physical_signoff=False,
        written_to=str(OUT/'final_review.json') if args.write else None),indent=2))


if __name__=='__main__':
    main()
