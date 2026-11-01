"""Continue the preserved 2022 GH2 SYN into exactly one reviewed MAP15.

Default preflight only reads evidence. --run consumes a separate claim after
the new actual-board RAM/FSM/CE proof passes. The original stopped native
driver, its twenty script bindings, source and external DE package stay intact.
There is no synthesis, placement, routing, promotion or bitstream operation.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys

from evaluate_g_candidate import frozen_sources, read, sha
from evaluate_gh2_candidate import visible_process_snapshot
from evaluate_h2_candidate import review_bridge_cdc
from review_gh2_functional import functional_proof


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA/'build/gh2_integration_20261101'
OUT = ROOT/'map_continuation_20261101'
CLAIM = ROOT/'map_dispatch_claim_20261101.json'
AUDIT = ROOT/'post_syn_review_20261101'
MODE = 'MAP15_FROM_VERIFIED_GH2_SYN_ONLY'
SUCCESS = 'GH2_MAP_COMPLETE_INDEPENDENT_REVIEW_REQUIRED'
DE_RESOURCES = {'LUT':37592,'FF':41960,'APM':154,'DRM':71.5,'Distributed RAM':1275}


def require(condition, reason):
    """Keep dispatch checks explicit; reused assertion auditors require -O off."""
    if not condition:
        raise ValueError(reason)


def hashes_intact(bindings):
    """Validate every bound path before continuing or accepting native output."""
    for name, digest in bindings.items():
        require(sha(Path(name)) == digest, 'Bound evidence changed: '+name)


def native_result(build, stage, budget):
    """Reject wrapper-only success, wrong phases, timeout and physical work."""
    result = read(build/'result.json')
    require(result['native_exit']==0 and not result['errors'] and result['snapshot_intact'],
            'Native result did not pass: '+str(build))
    supervision = result['supervision']
    require(result['stage']==stage and supervision['status']=='COMPLETED' and
            supervision['returncode']==0 and supervision['policy']['timeout_seconds']==budget,
            'Native phase/budget identity differs: '+str(build))
    require(not any(result.get(k,False) for k in
            ('placement_started','routed','bitstream_generated','programmed','dry_run')),
            'Unexpected dry-run, physical or programming work')
    return result


def immutable_inputs():
    """Bind the old terminal SYN and new independent proof without any writes.

This is also used after MAP, so it never rewrites or requires an empty new
continuation directory. The original failed outer gate remains evidence.
"""
    require(not sys.flags.optimize, 'Reused proof auditors require Python assertions')
    prior = read(ROOT/'native/state.json')
    require(prior['status']=='SYN_GATE_NEEDS_REVIEW', 'Original stopped SYN state changed')
    ended = json.loads((ROOT/'native_launch_exit.json').read_text(encoding='utf-8-sig'))
    started = json.loads((ROOT/'native_launch_started.json').read_text(encoding='utf-8-sig'))
    require(ended['returncode']==1 and ended['wrapper_pid']==started['wrapper_pid'],
            'Original gate-stop launcher evidence missing')
    require(datetime.fromisoformat(ended['ended_at']) > datetime.fromisoformat(started['started_at']),
            'Invalid original launcher chronology')
    require(prior['synthesis_wrapper_exit']==0 and set(prior['completed_artifacts_sha256'])=={'synthesis'},
            'Original run must contain only one completed SYN')
    original_scripts = read(ROOT/'native/scripts.json')
    require(len(original_scripts)==20, 'Original twenty-script closure changed')
    hashes_intact(original_scripts)
    hashes_intact(prior['completed_artifacts_sha256']['synthesis'])
    require(sha(ROOT/'native/driver.py')==sha(FPGA/'scripts/evaluate_gh2_candidate.py'),
            'Original frozen driver changed')
    candidate = ROOT/'candidate'
    manifest, proof = functional_proof(candidate)
    require(prior['functional']==proof and prior['sources_sha256']==proof['sources_sha256'],
            'Original SYN functional binding changed')
    syn = Path(prior['synthesis'])
    require(syn.resolve()==FPGA/'build/full_integration_20261013/board_20261101_103105_502401',
            'Continuation must use the precise preserved GH2 SYN')
    require(frozen_sources(syn)==manifest, 'SYN/candidate 327 source closure differs')
    native_result(syn,'synthesize',2700)
    require(prior['synthesis_result_sha256']==sha(syn/'result.json'), 'Original SYN result drift')
    require(not list((syn/'synthesize').glob('*.lock')), 'SYN database is still locked')
    # Import only after old evidence has passed. A missing or incomplete new
    # independent audit is a hard stop, never a provisional MAP authorization.
    from review_gh2_postsyn import verify_review
    gate = verify_review()
    require(gate['passed'] and gate['status']=='GH2_SYN_RAM_FSM_CE_VERIFIED_MAP_ALLOWED',
            'New actual-board RAM/FSM/CE proof is incomplete')
    require(Path(gate['synthesis']).resolve()==syn.resolve() and
            gate['sources_sha256']==proof['sources_sha256'] and gate['functional']==proof,
            'New netlist proof does not bind this SYN/function/source set')
    require(gate['vm_sha256']==sha(syn/'synthesize/pango_video_system_syn.vm'), 'New VM identity differs')
    hashes_intact(gate['evidence_sha256'])
    ram = read(AUDIT/'board_ram_mapping_gate.json')
    require(ram['passed'] and ram['vm_sha256']==gate['vm_sha256'], 'Actual RAM proof is incomplete')
    paths = [candidate/'sources.json',Path(proof['path']),ROOT/'native/state.json',
        ROOT/'native/scripts.json',ROOT/'native/driver.py',ROOT/'native_dispatch_claim.json',
        ROOT/'native_launch_started.json',ROOT/'native_launch_exit.json',AUDIT/'review.json',
        AUDIT/'board_ram_mapping_gate.json',AUDIT/'fsm_semantics.json',
        AUDIT/'ce_review.json',AUDIT/'negative_tests.json']
    bound = {str(p):sha(p) for p in paths}
    bound.update(original_scripts)
    bound.update(prior['completed_artifacts_sha256']['synthesis'])
    bound.update(gate['evidence_sha256'])
    return dict(candidate=candidate,synthesis=syn,manifest=manifest,functional=proof,
                netlist_gate=gate,ram_gate=ram,bound=bound)


def script_binding():
    """Freeze all new orchestration/review logic alongside the original closure."""
    names = ('evaluate_gh2_map_only.py','finalize_gh2_map_continuation.py',
             'review_gh2_postsyn.py','audit_gh2_parent_guards.py','audit_gh2_fsm_semantics.py',
             'finalize_gh2_validation.py','finalize_h2_validation.py')
    paths=[FPGA/'scripts'/n for n in names]+[ROOT/'launch_map_continuation_20261101.ps1']
    return {str(p):sha(p) for p in paths}


def preflight():
    """Never queue behind active work and never retry a consumed continuation."""
    require(not OUT.exists() and not CLAIM.exists(), 'GH2 MAP continuation/claim exists; inspect, never rerun')
    require(not (ROOT/'map_launch_exit.json').exists(), 'Existing MAP launcher exit requires review')
    data = immutable_inputs()
    data['scripts'] = script_binding()
    data['process'] = visible_process_snapshot()
    return data


def verify_map_identity(syn, mapping, manifest):
    """Check MAP output, copied SYN and all 327 sources, not only exit status."""
    result = native_result(mapping,'dev_map',900)
    require(frozen_sources(mapping)==manifest, 'MAP 327 source closure differs')
    require(Path(result['parent_build']).resolve()==syn.resolve() and result['syn_intact'],
            'MAP did not inherit the precise SYN')
    require(result['syn_sha256']==sha(syn/'synthesize/pango_video_system_syn.adf')==
            sha(mapping/'synthesize/pango_video_system_syn.adf'), 'Inherited SYN database changed')
    require(sha(syn/'synthesize/pango_video_system_syn.vm')==
            sha(mapping/'synthesize/pango_video_system_syn.vm'), 'Inherited SYN VM changed')
    require(result['mapped_database_sha256']==sha(mapping/'device_map/pango_video_system_map.adf'),
            'MAP database hash differs')
    return result


def mapping_review(syn, mapping, out, proof, ram):
    """Reuse actual SCF/CCR/CDC checks and compare every estimated clock to DE."""
    from review_gray_candidates import inspect
    from combined_cdc_gate import review_cdc
    from finalize_gray_verification import timing_summary
    review = inspect(syn,mapping)
    checks = review['constraints']
    require(checks['postsyn_constraint_gate']['command_count']==10 and
            checks['constraint_check']['diagnostic_counts']=={'ConstraintEditor-2002':33},
            'Unexpected post-SYN SCF/CCR diagnostics')
    review_cdc(syn,mapping,out)
    review_bridge_cdc(syn,mapping,out,ram)
    de = FPGA/'build/DE_optimization_20261031'
    ds = read(de/'native/state.json'); dm = frozen_sources(de/'candidate')
    require(ds['status']=='FUNCTIONAL_SYN_MAP_VERIFIED_PRE_ROUTE', 'DE baseline state changed')
    bs,bm = Path(ds['synthesis']),Path(ds['mapping'])
    for name,build in (('synthesis',bs),('mapping',bm)):
        require(frozen_sources(build)==dm and sha(build/'result.json')==ds[name+'_result_sha256'],
                'DE baseline evidence changed')
    baseline = inspect(bs,bm); timing = timing_summary(syn); old_timing = timing_summary(bs)
    require(baseline['mapping_resources']==DE_RESOURCES, 'Unexpected DE resource baseline')
    require(set(timing['estimated_setup_ns'])==set(old_timing['estimated_setup_ns']), 'Clock set differs from DE')
    review.update(status=SUCCESS,functional=proof,timing=timing,baseline_DE_timing=old_timing,
        baseline_DE_resources=DE_RESOURCES,delta_vs_DE={k:v-DE_RESOURCES[k] for k,v in review['mapping_resources'].items()},
        estimated_setup_delta_vs_DE={k:v-old_timing['estimated_setup_ns'][k] for k,v in timing['estimated_setup_ns'].items()},
        actual_netlist_review=str(AUDIT/'review.json'),physical_signoff=False,routing_started=False,
        promoted=False,bitstream_generated=False)
    return review


def run(data):
    """Consume a one-use claim; failures persist and propagate a nonzero exit."""
    claim = dict(started_at=datetime.now().astimezone().isoformat(),driver_pid=os.getpid(),mode=MODE,
        synthesis=str(data['synthesis']),sources_sha256=data['functional']['sources_sha256'],
        functional_sha256=data['functional']['sha256'],netlist_review_sha256=sha(AUDIT/'review.json'))
    with CLAIM.open('x',encoding='utf-8') as stream:
        json.dump(claim,stream,indent=2)
    OUT.mkdir(exist_ok=False)
    (OUT/'driver.py').write_bytes(Path(__file__).read_bytes())
    (OUT/'scripts.json').write_text(json.dumps(data['scripts'],indent=2),encoding='utf-8')
    (OUT/'process_preflight.json').write_text(json.dumps(data['process'],indent=2),encoding='utf-8')
    (OUT/'board_ram_mapping_gate.json').write_bytes((AUDIT/'board_ram_mapping_gate.json').read_bytes())
    state = dict(status='PREPARING_MAP',mode=MODE,driver_pid=os.getpid(),candidate=str(data['candidate']),
        synthesis=str(data['synthesis']),source_count=327,sources_sha256=claim['sources_sha256'],
        functional=data['functional'],bound=data['bound'],scripts=data['scripts'],
        netlist_review=str(AUDIT/'review.json'),routing_started=False,promoted=False,bitstream_generated=False)
    stop = OUT/'stop_requested.json'

    def publish(status):
        """Publish precise dynamic MAP identity atomically for bounded monitors."""
        state.update(status=status,updated_at=datetime.now().astimezone().isoformat())
        temp=OUT/'state.tmp';temp.write_text(json.dumps(state,indent=2),encoding='utf-8');temp.replace(OUT/'state.json')

    def unchanged():
        """Preserve original proof and frozen sources across the native boundary."""
        require(not stop.exists(), 'Stop requested; do not start/accept another native phase')
        hashes_intact(data['bound']);hashes_intact(data['scripts'])
        manifest,proof = functional_proof(data['candidate'])
        require(manifest==data['manifest'] and proof==data['functional'], 'Functional proof/source drift')
        require(frozen_sources(data['synthesis'])==manifest, 'Frozen SYN source drift')

    try:
        unchanged();visible_process_snapshot()
        command=[sys.executable,'-B',str(FPGA/'scripts/map_postsyn_candidate.py'),
                 '--build',str(data['synthesis']),'--pause-file',str(stop)]
        (OUT/'command.json').write_text(json.dumps(command,indent=2),encoding='utf-8')
        env=os.environ.copy();env.update(PYTHONUTF8='1',PYTHONIOENCODING='utf-8')
        publish('MAPPING')
        with (OUT/'mapping.log').open('w',encoding='utf-8') as log:
            child=subprocess.Popen(command,cwd=FPGA.parent,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                text=True,encoding='utf-8',errors='replace',env=env)
            state['active_wrapper_pid']=child.pid;publish('MAPPING')
            for line in child.stdout:
                log.write(line);log.flush()
                if line.startswith('POSTSYN_CANDIDATE '):
                    require('mapping' not in state, 'Multiple MAP output markers')
                    state['mapping']=line.split(' ',1)[1].strip();publish('MAPPING')
            state['mapping_wrapper_exit']=child.wait()
        state['active_wrapper_pid']=None
        require(state['mapping_wrapper_exit']==0, 'MAP wrapper failed; retain exact result')
        mapping=Path(state['mapping'])
        require(mapping.resolve().parent==FPGA/'build/full_integration_20261013' and
                mapping.name.startswith('board_postsyn_'), 'Unexpected MAP directory')
        verify_map_identity(data['synthesis'],mapping,data['manifest']);unchanged()
        process=visible_process_snapshot()
        (OUT/'terminal_process.json').write_text(json.dumps(process,indent=2),encoding='utf-8')
        artifacts=[mapping/'result.json',mapping/'sources.json',mapping/'synthesize/pango_video_system_syn.adf',
            mapping/'synthesize/pango_video_system_syn.vm',mapping/'synthesize/pango_video_system.snr',
            mapping/'device_map/pango_video_system_map.adf',mapping/'device_map/pango_video_system.dmr',
            mapping/'constraint_check/constraint_check.ccr']
        state['mapping_artifacts_sha256']={str(p):sha(p) for p in artifacts}
        state['mapping_result_sha256']=sha(mapping/'result.json')
        review=mapping_review(data['synthesis'],mapping,OUT,data['functional'],data['ram_gate'])
        (OUT/'review.json').write_text(json.dumps(review,indent=2),encoding='utf-8')
        unchanged();hashes_intact(state['mapping_artifacts_sha256'])
        state.update(resources=review['mapping_resources'],review=str(OUT/'review.json'))
        publish(SUCCESS)
        print(json.dumps(dict(status=SUCCESS,mapping=str(mapping),resources=state['resources']),indent=2))
    except Exception as error:
        state['error']=str(error);publish('FAILED');raise


def main():
    """No default launch and no dry-run native stage: validation is read-only."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run',action='store_true')
    args=parser.parse_args();data=preflight()
    if args.run:
        run(data)
    else:
        print(json.dumps(dict(status='GH2_MAP_PREFLIGHT_PASSED_NOT_STARTED',synthesis=str(data['synthesis']),
            functional=data['functional'],netlist_review_sha256=sha(AUDIT/'review.json'),
            bound=data['bound'],scripts=data['scripts'],process=data['process']),indent=2))


if __name__=='__main__':
    main()
