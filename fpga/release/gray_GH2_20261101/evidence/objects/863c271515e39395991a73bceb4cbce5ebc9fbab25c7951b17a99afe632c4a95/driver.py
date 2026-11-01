"""Evaluate exactly one frozen G+H2 candidate through SYN45, review, MAP15.

Default preflight is read-only. --run consumes a one-use claim and never queues,
restarts, promotes, routes or generates a bitstream. Original G/H2 artifacts
are immutable inputs. Unknown GH2 VM form stops for independent review.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys

from evaluate_g_candidate import frozen_sources, read, sha
from evaluate_h2_candidate import review_bridge_cdc
from review_gh2_netlist import review as review_netlist, TOPOLOGY_HELPER


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/gh2_integration_20261101'
LOCK = FPGA / 'build/route_optimization/native_phase.lock'
CHANGES = {'rtl/control/frame_parameter_bank.sv', 'rtl/memory/dma_write_cdc.sv',
           'constraints/video_system/processing_cdc.fdc'}


def visible_process_snapshot():
    """Require visible CIM identity before claiming the shared native resource."""
    command = r"""$ErrorActionPreference='Stop';
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);
$self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID);
if(-not $self.CommandLine -or -not $self.ExecutablePath){throw 'CIM identity not visible'};
$all=@(Get-CimInstance Win32_Process);
$pds=@($all | Where-Object {$_.Name -match '^(pds|pds_shell|pango_design_suite|synplify_pro|synthesis|map|ads|pds_gui)\.exe$' -or $_.ExecutablePath -like 'E:\PDS_Pangu\*'} | Select-Object ProcessId,ParentProcessId,Name,CreationDate,ExecutablePath,CommandLine);
[ordered]@{checked_at=(Get-Date -Format o);query_succeeded=$true;query_self_pid=$PID;processes=$pds} | ConvertTo-Json -Depth 5
"""
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command],
        check=False, capture_output=True, text=True, encoding='utf-8-sig', errors='strict', timeout=30)
    if result.returncode:
        raise RuntimeError('Visible CIM query failed; no start: '+result.stderr.strip()[:2000])
    evidence = json.loads(result.stdout)
    if not evidence['query_succeeded'] or evidence['processes']:
        raise RuntimeError('Active PDS process or unavailable visible identity; no native start')
    if LOCK.exists():
        raise RuntimeError('Native phase lock exists')
    return evidence


def script_binding():
    """Bind reused orchestration/auditors so no in-flight logic changes silently."""
    names = ('evaluate_gh2_candidate.py', 'review_gh2_functional.py', 'review_gh2_netlist.py',
        'evaluate_g_candidate.py', 'evaluate_h2_candidate.py', 'review_g_netlist.py',
        'audit_h2_parent_guards.py', 'audit_h2_fsm_semantics.py', 'gate_h2_read_port.py',
        'build_video_system.py', 'map_postsyn_candidate.py', 'route_supervisor.py',
        'constraint_report.py', 'implementation_readiness.py', 'native_bitgen.py',
        'review_gray_candidates.py', 'combined_cdc_gate.py', 'combined_candidate_gate.py',
        'finalize_gray_verification.py')
    paths = [FPGA/'scripts'/name for name in names] + [TOPOLOGY_HELPER]
    return {str(p):sha(p) for p in paths}


def preflight():
    """No writes or waiting; new combined functional evidence is mandatory."""
    from review_gh2_functional import functional_proof
    if sys.flags.optimize:
        raise RuntimeError('Assertions are required by the reused evidence auditors; run without Python optimization')
    if (ROOT/'native').exists() or (ROOT/'native_dispatch_claim.json').exists():
        raise RuntimeError('GH2 native/claim already exists: inspect, never rerun')
    candidate = ROOT/'candidate'
    manifest, proof = functional_proof(candidate)
    if Path(proof['path']).resolve() != ROOT/'functional_review.json' or proof['sha256'] != sha(Path(proof['path'])):
        raise RuntimeError('Functional proof identity mismatch')
    original = frozen_sources(FPGA/'build/DE_optimization_20261031/candidate')
    if set(original) != set(manifest) or {n for n in original if original[n] != manifest[n]} != CHANGES:
        raise RuntimeError('Only the three reviewed G/H2 files may differ from DE')
    g = frozen_sources(FPGA/'build/parameter_ce_20261031/G_integration/candidate')
    h2 = frozen_sources(FPGA/'build/write_cdc_owned_read_20261031/H2_candidate')
    if manifest['rtl/control/frame_parameter_bank.sv'] != g['rtl/control/frame_parameter_bank.sv']:
        raise RuntimeError('G bank bytes differ')
    if any(manifest[n] != h2[n] for n in manifest if n != 'rtl/control/frame_parameter_bank.sv'):
        raise RuntimeError('GH2 must be H2 plus the exact G bank only')
    scripts = script_binding()
    process = visible_process_snapshot()
    return candidate, manifest, proof, scripts, process


def main():
    """Use existing bounded native supervisors; MAP follows both actual VM gates."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    candidate, manifest, proof, scripts, process = preflight()
    if not args.run:
        print(json.dumps(dict(status='GH2_PREFLIGHT_PASSED_NOT_STARTED', functional=proof,
            sources_sha256=sha(candidate/'sources.json'), scripts=scripts, process=process), indent=2)); return
    # Two competing dispatchers cannot both consume this candidate. Never
    # delete the claim after failure: evidence, rather than a retry, decides next.
    claim = dict(started_at=datetime.now().astimezone().isoformat(), driver_pid=os.getpid(),
        candidate=str(candidate), sources_sha256=sha(candidate/'sources.json'), functional_sha256=proof['sha256'])
    with (ROOT/'native_dispatch_claim.json').open('x', encoding='utf-8') as stream:
        json.dump(claim, stream, indent=2)
    out = ROOT/'native'; out.mkdir(exist_ok=False)
    (out/'driver.py').write_bytes(Path(__file__).read_bytes())
    (out/'scripts.json').write_text(json.dumps(scripts,indent=2),encoding='utf-8')
    (out/'process_preflight.json').write_text(json.dumps(process,indent=2),encoding='utf-8')
    state = dict(status='PREPARING', driver_pid=os.getpid(), candidate=str(candidate),
        source_count=327, sources_sha256=claim['sources_sha256'], functional=proof,
        routing_started=False, promoted=False, bitstream_generated=False)
    stop = out/'stop_requested.json'

    def publish(status):
        """Atomic stage pointer prevents consumers from guessing newest directories."""
        state.update(status=status, updated_at=datetime.now().astimezone().isoformat())
        temp = out/'state.tmp'; temp.write_text(json.dumps(state,indent=2),encoding='utf-8'); temp.replace(out/'state.json')

    def unchanged():
        """Check source, proof and all driver/auditor bytes at every stage boundary."""
        if stop.exists() or frozen_sources(candidate) != manifest or sha(Path(proof['path'])) != proof['sha256']:
            raise RuntimeError('Stop request, source drift or changed functional proof')
        if any(sha(Path(p)) != digest for p,digest in scripts.items()):
            raise RuntimeError('Native/audit script drift')
        # Revalidate the evidence behind the fixed review too: a stable review
        # file alone cannot prove that its video, unit or consumer inputs stayed.
        from review_gh2_functional import functional_proof
        current_manifest, current_proof = functional_proof(candidate)
        if current_manifest != manifest or current_proof != proof:
            raise RuntimeError('Functional dependency evidence changed')
        for paths in state.get('completed_artifacts_sha256', {}).values():
            if any(sha(Path(p)) != digest for p,digest in paths.items()):
                raise RuntimeError('Completed native artifacts changed')

    def stage(name, command, marker):
        """Execute only the declared stage; supervisors enforce 45/15 minute bounds."""
        unchanged(); visible_process_snapshot()
        (out/(name+'.command.json')).write_text(json.dumps(command,indent=2),encoding='utf-8')
        env = os.environ.copy(); env.update(PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
        publish(name.upper())
        with (out/(name+'.log')).open('w',encoding='utf-8') as log:
            child = subprocess.Popen(command,cwd=FPGA.parent,env=env,stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace')
            state['active_wrapper_pid']=child.pid; publish(name.upper())
            for line in child.stdout:
                log.write(line); log.flush()
                if line.startswith(marker+' '):
                    state[name]=line[len(marker)+1:].strip(); publish(name.upper())
            returncode = child.wait()
        state['active_wrapper_pid']=None; state[name+'_wrapper_exit']=returncode
        if returncode != 0:
            raise RuntimeError(name+' wrapper failed; retain exact output')
        build = Path(state[name]); result = read(build/'result.json')
        if result['native_exit'] != 0 or result['errors'] or not result['snapshot_intact']:
            raise RuntimeError(name+' native result did not pass')
        if frozen_sources(build) != manifest:
            raise RuntimeError(name+' source mismatch')
        terminal_process = visible_process_snapshot()
        (out/(name+'.terminal_process.json')).write_text(json.dumps(terminal_process,indent=2),encoding='utf-8')
        # The same completed SYN database, VM and timing report are reviewed
        # and supplied to MAP. MAP products are then bound for final auditing.
        paths = [build/'result.json', build/'sources.json',
            build/'synthesize/pango_video_system_syn.adf',
            build/'synthesize/pango_video_system_syn.vm',
            build/'synthesize/pango_video_system.snr']
        if name == 'mapping':
            paths += [build/'device_map/pango_video_system_map.adf',
                      build/'device_map/pango_video_system.dmr',
                      build/'constraint_check/constraint_check.ccr']
        state.setdefault('completed_artifacts_sha256', {})[name] = {str(p):sha(p) for p in paths}
        state[name+'_result_sha256']=sha(build/'result.json'); unchanged()
        return build

    try:
        syn=stage('synthesis',[sys.executable,'-B',str(FPGA/'scripts/build_video_system.py'),
            '--rtl-snapshot',str(candidate/'source'),'--stage','synthesize',
            '--overall-timeout-minutes','45','--pause-file',str(stop)],'BOARD_START')
        publish('SYN_NETLIST_REVIEW')
        audit_dir = out/'netlist_review'
        gate = review_netlist(syn,candidate,audit_dir)
        state['netlist_review']=str(audit_dir/'review.json')
        if not gate['passed']:
            state['error']=gate.get('error','Unknown netlist form')
            publish('SYN_GATE_NEEDS_REVIEW')
            raise RuntimeError('New GH2 actual-board RAM/FSM/CE gate needs review; no MAP started')
        gate_hashes = {str(p):sha(p) for p in audit_dir.glob('*.json')}
        state['netlist_gate_sha256']=gate_hashes; unchanged()
        mapping=stage('mapping',[sys.executable,'-B',str(FPGA/'scripts/map_postsyn_candidate.py'),
            '--build',str(syn),'--pause-file',str(stop)],'POSTSYN_CANDIDATE')
        if any(sha(Path(p)) != h for p,h in gate_hashes.items()):
            raise RuntimeError('MAP-stage netlist proof drift')
        from review_gray_candidates import inspect
        from combined_cdc_gate import review_cdc
        from finalize_gray_verification import timing_summary
        review = inspect(syn,mapping)
        constraints = review['constraints']
        if constraints['postsyn_constraint_gate']['command_count'] != 10 or constraints['constraint_check']['diagnostic_counts'] != {'ConstraintEditor-2002':33}:
            raise RuntimeError('Unexpected SCF/CCR result; preserve all new diagnostics')
        review_cdc(syn,mapping,out)
        # The bridge checker binds its output to this same completed VM gate.
        (out/'board_ram_mapping_gate.json').write_bytes((audit_dir/'board_ram_mapping_gate.json').read_bytes())
        review_bridge_cdc(syn,mapping,out,read(out/'board_ram_mapping_gate.json'))
        timing = timing_summary(syn)
        de_state=read(FPGA/'build/DE_optimization_20261031/native/state.json')
        baseline_syn, baseline_map = Path(de_state['synthesis']), Path(de_state['mapping'])
        baseline_manifest=frozen_sources(FPGA/'build/DE_optimization_20261031/candidate')
        if de_state['status'] != 'FUNCTIONAL_SYN_MAP_VERIFIED_PRE_ROUTE' or any(
            frozen_sources(build) != baseline_manifest or sha(build/'result.json') != de_state[key]
            for build,key in ((baseline_syn,'synthesis_result_sha256'),(baseline_map,'mapping_result_sha256'))):
            raise RuntimeError('DE comparison identity changed')
        de = inspect(baseline_syn,baseline_map)
        if de['mapping_resources'] != {'LUT':37592,'FF':41960,'APM':154,'DRM':71.5,'Distributed RAM':1275}:
            raise RuntimeError('Unexpected DE resource baseline')
        baseline_timing=timing_summary(baseline_syn)
        expected_clocks=baseline_timing['estimated_setup_ns']
        if set(timing['estimated_setup_ns']) != set(expected_clocks):
            raise RuntimeError('Unexpected clock set')
        review.update(status='GH2_SYN_MAP_COMPLETE_INDEPENDENT_REVIEW_REQUIRED',timing=timing,
            baseline_DE_resources=de['mapping_resources'],
            delta_vs_DE={k:v-de['mapping_resources'][k] for k,v in review['mapping_resources'].items()},
            baseline_DE_timing=baseline_timing,
            estimated_setup_delta_vs_DE={k:v-expected_clocks[k] for k,v in timing['estimated_setup_ns'].items()},
            clocks_with_negative_estimated_setup={k:v for k,v in timing['estimated_setup_ns'].items() if v<0},
            functional=proof, completed_artifacts_sha256=state['completed_artifacts_sha256'],
            actual_netlist_review=str(audit_dir/'review.json'),physical_signoff=False,
            routing_started=False,promoted=False,bitstream_generated=False)
        (out/'review.json').write_text(json.dumps(review,indent=2),encoding='utf-8')
        unchanged(); state.update(resources=review['mapping_resources'],review=str(out/'review.json'))
        publish('SYN_MAP_COMPLETE_INDEPENDENT_REVIEW_REQUIRED')
    except Exception as error:
        state['error']=str(error)
        publish('SYN_GATE_NEEDS_REVIEW' if state['status']=='SYN_GATE_NEEDS_REVIEW' else 'FAILED')
        raise


if __name__ == '__main__':
    main()
