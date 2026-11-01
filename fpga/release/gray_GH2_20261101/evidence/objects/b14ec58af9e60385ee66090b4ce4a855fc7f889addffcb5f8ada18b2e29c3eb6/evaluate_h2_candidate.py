"""Evaluate frozen H2 owned-read CDC with one SYN45/MAP15 sequence.

Default is read-only preflight; --run is explicit and never queues. Reuse G's
source/release helpers and existing native supervisors. No PnR, promotion,
readiness change, bitstream, or modification of any active candidate occurs.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from evaluate_g_candidate import sha, read, frozen_sources, release_proof, DEFAULT_RELEASE


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/write_cdc_owned_read_20261031'
CHANGE = 'rtl/memory/dma_write_cdc.sv'


def constraint_adaptation(candidate):
    """Retire only obsolete read_q FF bounds; preserve all other timing commands."""
    name = 'constraints/video_system/processing_cdc.fdc'
    before = FPGA / 'build/DE_optimization_20261031/candidate/source' / name
    after = candidate / 'source' / name
    # Compare every executable line, including any clock command or indented
    # command, so a new exception cannot hide outside a set_* line filter.
    old = [line.strip() for line in before.read_text().splitlines()
           if line.strip() and not line.lstrip().startswith('#')]
    current = [line.strip() for line in after.read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('#')]
    removed = [line for line in old if 'result_bridge.read_q*' in line]
    if len(removed) != 2 or current != [line for line in old if line not in removed]:
        raise RuntimeError('H2 may retire only the two obsolete read_q FF exceptions')
    if not removed[0].startswith('set_max_delay 6.0 -datapath_only ') or not removed[1].startswith('set_false_path -hold '):
        raise RuntimeError('Unexpected retired constraint semantics')
    return dict(removed_commands=removed, processing_cdc_sha256=sha(after),
                no_new_or_broadened_commands=True, full_board_topology_gate_required=True)


def functional_proof(candidate):
    """Bind eight new H2 ownership scenarios and fresh full1080p to 327 inputs."""
    manifest = frozen_sources(candidate)
    baseline = FPGA / 'build/DE_optimization_20261031/candidate'
    original = frozen_sources(baseline)
    expected = {CHANGE, 'constraints/video_system/processing_cdc.fdc'}
    changed = {n for n in original if original[n] != manifest[n]}
    if set(manifest) != set(original) or changed != expected:
        raise RuntimeError('H2 must change exactly dma_write_cdc and processing_cdc')
    constraints = constraint_adaptation(candidate)
    proof = ROOT / 'functional_review.json'; result = read(proof)
    if result.get('passed') is not True or result.get('candidate_manifest_sha256') != sha(candidate / 'sources.json'):
        raise RuntimeError('H2 functional review missing or belongs to another revision')
    if Path(result['candidate']).resolve() != candidate.resolve() or set(result['changes_vs_DE']) != expected:
        raise RuntimeError('Wrong H2 candidate or change closure')
    adaptation = result['constraint_adaptation']
    if adaptation.get('full_board_topology_gate_required') is not True or adaptation['removed_commands'] != constraints['removed_commands']:
        raise RuntimeError('H2 retired constraints not bound to a mandatory board mapping gate')
    unit = result['unit_proof']; path = Path(unit['path'])
    if sha(path / 'result.json') != unit['result_sha256'] or sha(path / 'sources.json') != unit['sources_sha256']:
        raise RuntimeError('H2 unit proof hashes changed')
    ur = read(path / 'result.json'); um = read(path / 'sources.json')
    if not ur.get('passed') or not ur.get('inputs_intact') or len(ur.get('scenarios', [])) != 8:
        raise RuntimeError('H2 eight-scenario ownership proof incomplete')
    if any(sha(path / n) != h for n,h in um.items()):
        raise RuntimeError('H2 frozen unit inputs drifted')
    if um.get('dma_write_cdc.sv') != manifest[CHANGE] or um.get('baseline_original.sv') != original[CHANGE]:
        raise RuntimeError('H2 unit proof does not bind exact H2/DE source')
    before = (path / 'baseline_original.sv').read_text()
    if before.replace('module dma_write_cdc(', 'module dma_write_cdc_baseline(', 1) != (path / 'baseline_sim.sv').read_text():
        raise RuntimeError('H2 DE comparator is not an exact module rename')
    coverage = {'same_538_cases_as_H1','no_reads_during_client_collection',
        'source_write_never_overlaps_read_enable','disabled_read_result_stable',
        'immediate_one_beat_reuse_while_memory_ack','m_load_zero_beat_normal_and_error_completion',
        'last_beat_same_edge_completion'}
    if set(ur.get('coverage',[])) != coverage:
        raise RuntimeError('H2 ownership/edge coverage changed')
    cases = beats = reuse = 0; suites = []
    for index, scenario in enumerate(ur['scenarios']):
        suites.append(scenario['suite'])
        if [(x['stage'],x['returncode']) for x in scenario['phases']] != [('compile',0),('run',0)]:
            raise RuntimeError('H2 scenario did not finish successfully')
        text = (path / f'{index}_run.log').read_text(errors='replace')
        marker = 'DMA_WRITE_CAPTURE_PASS' if scenario['suite'] == 'unit' else 'H_EDGE_PASS'
        match = re.search(marker+r' cases=(\d+) requests=(\d+) beats=(\d+)',text)
        if not match or any(k not in text for k in ('H_DIFF_PASS','H2_OWNERSHIP_PASS')) or scenario['summary'].replace('\r\n','\n') != text:
            raise RuntimeError('H2 ownership/differential/oracle markers missing')
        cases += int(match[1]); beats += int(match[3])
        if scenario['suite'] == 'edge':
            edge = re.search(r'reuse_while_ack=(\d+) zero_normal=(\d+) zero_error=(\d+) last_with_done=(\d+)',text)
            if not edge or tuple(map(int,edge.groups())) != (60,4,4,16):
                raise RuntimeError('H2 completion edge coverage missing')
            reuse += int(edge[1])
    if suites != ['unit']*5+['edge']*3 or (cases,beats,reuse) != (538,3199,180):
        raise RuntimeError('Unexpected H2 proof coverage')
    video = result['full_video']; run = Path(video['path'])
    if not video.get('fresh_run') or sha(run / 'result.json') != video['result_sha256'] or sha(run / 'sources.json') != video['sources_sha256']:
        raise RuntimeError('H2 fresh full-video evidence drift')
    vr = read(run / 'result.json'); vm = read(run / 'sources.json')
    flags = ('passed','full_frame','display_test','control_test','board_manual_profile',
             'source_gamma','fixed_gray','stop_to_update','projective','snapshot_intact')
    if not all(vr.get(k) for k in flags) or CHANGE not in vm:
        raise RuntimeError('Incomplete H2 full-video proof')
    for name,digest in vm.items():
        if sha(run / 'source' / name) != digest or (name.startswith('rtl/') and digest != manifest[name]):
            raise RuntimeError('H2 full-video input mismatch: '+name)
    text = (run / 'run.log').read_text(errors='replace')
    for marker in ('DISPLAY_CORE_PASS new=3 repeat=5 checked_pixels=16588800 failed=0 underflow=0',
                   'STOP_TO_UPDATE_PASS','old_matrix_frozen=1','TB_VIDEO_MEMORY_CORE_PASS'):
        if marker not in text:raise RuntimeError('H2 display/drain proof incomplete')
    return manifest,dict(path=str(proof),sha256=sha(proof),sources_sha256=sha(candidate / 'sources.json'),
        unit_cases=cases,unit_beats=beats,immediate_reuses=reuse,constraint_adaptation=constraints)


def review_bridge_cdc(syn, mapping, out, ram_gate):
    """Check actual consumption of unchanged constraints after the board RAM gate."""
    adaptation = constraint_adaptation(mapping)
    if not ram_gate.get('passed') or ram_gate['vm_sha256'] != sha(syn / 'synthesize/pango_video_system_syn.vm'):
        raise RuntimeError('H2 full-board RAM gate absent or no longer matches SYN')
    name = 'constraints/video_system/processing_cdc.fdc'
    commands = [line.strip() for line in (mapping/'source'/name).read_text().splitlines() if line.startswith('set_')]
    dmr = mapping/'device_map/pango_video_system.dmr'; text = dmr.read_text(errors='replace')
    normalized = {' '.join(line.split()) for line in text.splitlines() if line.strip().startswith('set_')}
    missing = [line for line in commands if ' '.join(line.split()) not in normalized]
    if missing or any(line in text for line in adaptation['removed_commands']):
        raise RuntimeError('MAP processing CDC command set does not match the reviewed H2 adaptation')
    review = dict(passed=True,adaptation=adaptation,all_remaining_processing_commands_loaded=True,
        no_new_ram_module_or_clock_exceptions=True,board_ram_gate_sha256=sha(out/'board_ram_mapping_gate.json'),
        dmr_sha256=sha(dmr),normal_RAM_address_CE_and_consumer_timing_retained=True,physical_signoff=False)
    (out/'bridge_cdc_review.json').write_text(json.dumps(review,indent=2),encoding='utf-8')
    return review


def preflight(release):
    """Reject active native work immediately; there is no automatic queue."""
    if (FPGA / 'build/route_optimization/native_phase.lock').exists():
        raise RuntimeError('Existing native phase lock; leave current work untouched')
    candidate = ROOT / 'H2_candidate'
    manifest, functional = functional_proof(candidate)
    released = release_proof(release)
    if (ROOT / 'native').exists():
        raise RuntimeError('H native directory already exists; inspect, never relaunch')
    return candidate, manifest, functional, released


def main():
    """Use the existing bounded native flow and stop for structural review."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--de-release-review', type=Path, default=DEFAULT_RELEASE)
    args = parser.parse_args()
    candidate, manifest, functional, released = preflight(args.de_release_review)
    if not args.run:
        print(json.dumps(dict(status='PREFLIGHT_PASSED_NOT_STARTED', candidate=str(candidate),
            functional=functional, de_release=released, native_started=False), indent=2)); return
    out = ROOT / 'native'; out.mkdir(exist_ok=False)
    (out / 'driver.py').write_bytes(Path(__file__).read_bytes()); stop = out / 'stop_requested.json'
    names = ('evaluate_g_candidate.py', 'gate_h2_read_port.py', 'build_video_system.py', 'map_postsyn_candidate.py',
             'route_supervisor.py', 'implementation_readiness.py', 'constraint_report.py',
             'native_bitgen.py', 'review_gray_candidates.py', 'combined_cdc_gate.py',
             'combined_candidate_gate.py', 'finalize_gray_verification.py',
             'portable_de.py', 'portable_de_readiness.py')
    scripts = {n:sha(FPGA / 'scripts' / n) for n in names}
    (out / 'scripts.json').write_text(json.dumps(scripts, indent=2), encoding='utf-8')
    state = dict(status='PREPARING', driver_pid=os.getpid(), candidate=str(candidate),
        source_count=327, sources_sha256=functional['sources_sha256'], functional=functional,
        de_release=released, routing_started=False, live_rtl_modified=False,
        readiness_modified=False, bitstream_generated=False)

    def publish(status):
        state.update(status=status, updated_at=datetime.now().astimezone().isoformat())
        temporary = out / 'state.tmp'
        temporary.write_text(json.dumps(state, indent=2), encoding='utf-8'); temporary.replace(out / 'state.json')

    def stage(name, command, marker):
        """Guard the candidate/scripts before each existing supervised phase."""
        if (FPGA / 'build/route_optimization/native_phase.lock').exists():
            raise RuntimeError('Native lock appeared before ' + name)
        if stop.exists() or any(sha(FPGA / 'scripts' / n) != h for n,h in scripts.items()):
            raise RuntimeError('Stop requested or evaluation script drift')
        if frozen_sources(candidate) != manifest or sha(Path(functional['path'])) != functional['sha256']:
            raise RuntimeError('H functional input drift')
        if sha(args.de_release_review) != released['sha256']:
            raise RuntimeError('DE release review drift')
        (out / (name + '.command.json')).write_text(json.dumps(command, indent=2), encoding='utf-8')
        env = os.environ.copy(); env.update(PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
        publish(name.upper())
        with (out / (name + '.log')).open('w', encoding='utf-8') as log:
            child = subprocess.Popen(command, cwd=FPGA.parent, env=env, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
            state['active_wrapper_pid'] = child.pid; publish(name.upper())
            for line in child.stdout:
                log.write(line); log.flush()
                if line.startswith(marker + ' '):
                    state[name] = line[len(marker)+1:].strip(); publish(name.upper())
            code = child.wait()
        state['active_wrapper_pid'] = None
        if code:
            raise RuntimeError(name + ' failed; retain exact log')
        build = Path(state[name]); result = read(build / 'result.json')
        if result.get('native_exit') != 0 or result.get('errors') or not result.get('snapshot_intact'):
            raise RuntimeError(name + ' native evidence failed')
        if frozen_sources(build) != manifest:
            raise RuntimeError(name + ' source set differs from H')
        state[name + '_result_sha256'] = sha(build / 'result.json')
        return build

    try:
        syn = stage('synthesis', [sys.executable, '-B', str(FPGA / 'scripts/build_video_system.py'),
            '--rtl-snapshot', str(candidate / 'source'), '--stage', 'synthesize',
            '--overall-timeout-minutes', '45', '--pause-file', str(stop)], 'BOARD_START')
        # The obsolete read_q FF exception may be retired only after the REAL
        # whole-board SYN proves the intended owned SDP mapping. A leaf probe
        # or source attribute cannot authorize MAP.
        from gate_h2_read_port import review as board_mapping_review
        publish('SYN_BOARD_RAM_MAPPING_REVIEW')
        ram_gate = board_mapping_review(syn, out)
        if not ram_gate.get('passed'):
            state['mapping_blocked_by_board_ram_gate'] = True
            raise RuntimeError('SYN board RAM mapping NEEDS_REVIEW: '+ram_gate.get('reason','unknown'))
        state['board_ram_mapping_gate_sha256'] = sha(out/'board_ram_mapping_gate.json')
        # MAP's existing supervisor owns the fixed 900-second host budget.
        mapping = stage('mapping', [sys.executable, '-B', str(FPGA / 'scripts/map_postsyn_candidate.py'),
            '--build', str(syn), '--pause-file', str(stop)], 'POSTSYN_CANDIDATE')
        from review_gray_candidates import inspect
        from combined_cdc_gate import review_cdc
        from finalize_gray_verification import timing_summary
        ds = read(FPGA / 'build/DE_optimization_20261031/native/state.json')
        if ds.get('status') != 'FUNCTIONAL_SYN_MAP_VERIFIED_PRE_ROUTE':
            raise RuntimeError('DE baseline not complete')
        bsyn = Path(ds['synthesis']); bmap = Path(ds['mapping'])
        original = frozen_sources(FPGA / 'build/DE_optimization_20261031/candidate')
        if frozen_sources(bsyn) != original or frozen_sources(bmap) != original:
            raise RuntimeError('DE native comparison source mismatch')
        if sha(bsyn / 'result.json') != ds['synthesis_result_sha256'] or sha(bmap / 'result.json') != ds['mapping_result_sha256']:
            raise RuntimeError('DE native comparison result drift')
        base = inspect(bsyn, bmap); review = inspect(syn, mapping)
        if base['mapping_resources'] != {'LUT':37592, 'FF':41960, 'APM':154, 'DRM':71.5, 'Distributed RAM':1275}:
            raise RuntimeError('Unexpected DE resource baseline')
        gate = review['constraints']
        if gate['postsyn_constraint_gate']['command_count'] != 10 or gate['constraint_check']['diagnostic_counts'] != {'ConstraintEditor-2002':33}:
            raise RuntimeError('New MAP constraint diagnostics require review')
        review_cdc(syn, mapping, out)
        bridge_cdc = review_bridge_cdc(syn, mapping, out, ram_gate)
        _, final_functional = functional_proof(candidate)
        if final_functional != functional:
            raise RuntimeError('H functional proof changed during evaluation')
        timing = timing_summary(syn); btiming = timing_summary(bsyn)
        clocks = timing['estimated_setup_ns']; bclocks = btiming['estimated_setup_ns']
        if set(clocks) != set(bclocks):
            raise RuntimeError('H synthesis clock set changed')
        review.update(status='H2_SYN_MAP_BOARD_RAM_VERIFIED_REVIEW_REQUIRED', functional=functional,
            de_release=released, baseline_DE=dict(syn=str(bsyn), mapping=str(bmap)),
            baseline_DE_resources=base['mapping_resources'],
            delta_vs_DE={k:v-base['mapping_resources'][k] for k,v in review['mapping_resources'].items()},
            timing=timing, baseline_DE_timing=btiming,
            estimated_setup_delta_vs_DE={k:clocks[k]-bclocks[k] for k in clocks},
            clocks_with_negative_estimated_setup={k:v for k,v in clocks.items() if v<0},
            bridge_cdc_review=bridge_cdc,
            bridge_netlist_review=ram_gate,
            routing_started=False, routed_timing_verified=False, live_rtl_modified=False,
            readiness_modified=False, bitstream_generated=False, automatically_promoted=False)
        (ROOT / 'native_review.json').write_text(json.dumps(review, indent=2), encoding='utf-8')
        state.update(resources=review['mapping_resources'], review=str(ROOT / 'native_review.json'),
                     bridge_netlist_review='BOARD_RAM_MAPPING_GATE_PASSED')
        publish('SYN_MAP_BOARD_RAM_VERIFIED_REVIEW_REQUIRED')
    except Exception as error:
        state['error'] = str(error)
        publish('SYN_GATE_NEEDS_REVIEW' if state.get('mapping_blocked_by_board_ram_gate') else 'FAILED')
        raise


if __name__ == '__main__':
    main()
