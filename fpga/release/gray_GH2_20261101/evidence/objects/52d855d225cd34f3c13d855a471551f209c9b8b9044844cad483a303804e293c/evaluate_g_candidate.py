"""Evaluate frozen G CE32 with SYN/MAP after DE terminates and is packaged.

Default is read-only preflight. --run starts one bounded SYN45/MAP15 sequence;
neither mode promotes RTL, modifies readiness, routes, or generates a bitstream.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/parameter_ce_20261031/G_integration'
BANK = 'rtl/control/frame_parameter_bank.sv'
DE_BUILD = FPGA / 'build/full_integration_20261013/gray_DE_verified_pnr_20261031_203121'
DEFAULT_RELEASE = FPGA / 'build/de_release_preparation_20261031/release_review.json'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def frozen_sources(candidate):
    """Recheck the full 327-file closure, not merely the changed bank."""
    manifest = read(candidate / 'sources.json')
    if len(manifest) != 327 or any(sha(candidate / 'source' / n) != h for n, h in manifest.items()):
        raise RuntimeError('Frozen source closure mismatch: ' + str(candidate))
    return manifest


def functional_proof(candidate):
    """Bind the two-width unit proof, UART/reference consumers, and fresh video."""
    manifest = frozen_sources(candidate)
    baseline = FPGA / 'build/DE_optimization_20261031/candidate'
    original = frozen_sources(baseline)
    if set(manifest) != set(original) or [n for n in original if original[n] != manifest[n]] != [BANK]:
        raise RuntimeError('G must differ from DE only in frame_parameter_bank')
    proof = ROOT / 'functional_review.json'
    result = read(proof)
    if result.get('passed') is not True or result.get('candidate_manifest_sha256') != sha(candidate / 'sources.json'):
        raise RuntimeError('G functional review missing or belongs to another revision')
    if Path(result['candidate']).resolve() != candidate.resolve() or result.get('source_count') != 327:
        raise RuntimeError('Wrong G candidate in functional review')
    if result.get('source_changes') != [BANK] or Path(result['source_parent']).resolve() != baseline.resolve():
        raise RuntimeError('Functional review does not bind the DE parent')
    unit = Path(result['unit_proof'])
    if sha(unit / 'result.json') != result['unit_result_sha256']:
        raise RuntimeError('G unit result drift')
    ur = read(unit / 'result.json'); um = read(unit / 'sources.json')
    if not ur.get('passed') or not ur.get('inputs_intact'):
        raise RuntimeError('G unit proof incomplete')
    for name, item in um.items():
        if sha(unit / 'source' / name) != item['sha256']:
            raise RuntimeError('G unit frozen input drift: ' + name)
    if um['candidate_original.sv']['sha256'] != manifest[BANK] or um['baseline.sv']['sha256'] != original[BANK]:
        raise RuntimeError('G unit proof does not compare the selected bank bytes')
    expected = {'tb_reference_canonical_bank': 'REFERENCE_CANONICAL_BANK_PASS malformed=9 valid_commits=2',
                'tb_pc_raw_pose': 'PC_RAW_POSE_PASS serial_replies=19 raw_updates=2'}
    integrations = result['affected_integrations']
    if len(integrations) != 2 or {item['top'] for item in integrations} != set(expected):
        raise RuntimeError('Missing affected consumer integration')
    for item in integrations:
        run = Path(item['path'])
        if not item.get('passed') or sha(run / 'sources.json') != item['sources_sha256']:
            raise RuntimeError('G consumer proof drift')
        inputs = read(run / 'sources.json')
        for name, info in inputs.items():
            path = run / 'source' / name if name.endswith('.sv') else run / name
            if sha(path) != info['sha256'] or (name.startswith('rtl/') and info['sha256'] != manifest[name]):
                raise RuntimeError('G consumer input mismatch: ' + name)
        if expected[item['top']] not in (run / 'run.log').read_text(errors='replace'):
            raise RuntimeError('G consumer result is not passing')
    video = result['full_video']; run = Path(video['path'])
    if not video.get('fresh_run') or sha(run / 'result.json') != video['result_sha256'] or sha(run / 'sources.json') != video['sources_sha256']:
        raise RuntimeError('Fresh G full-video evidence drift')
    vr = read(run / 'result.json'); vm = read(run / 'sources.json')
    flags = ('passed', 'full_frame', 'display_test', 'control_test', 'fixed_gray',
             'stop_to_update', 'projective', 'snapshot_intact')
    if not all(vr.get(k) for k in flags) or BANK not in vm:
        raise RuntimeError('Incomplete G full-video proof')
    for name, digest in vm.items():
        if sha(run / 'source' / name) != digest or (name.startswith('rtl/') and digest != manifest[name]):
            raise RuntimeError('G full-video input mismatch: ' + name)
    log = (run / 'run.log').read_text(errors='replace')
    for marker in ('DISPLAY_CORE_PASS new=3 repeat=5 checked_pixels=16588800 failed=0 underflow=0',
                   'STOP_TO_UPDATE_PASS', 'TB_VIDEO_MEMORY_CORE_PASS'):
        if marker not in log:
            raise RuntimeError('Missing full-video drain/display evidence')
    return manifest, dict(path=str(proof), sha256=sha(proof),
                         sources_sha256=sha(candidate / 'sources.json'))


def release_proof(path):
    """Require terminal DE and an intact relocation package before using PDS."""
    item = read(path)
    if not all(item.get(k) is True for k in ('passed', 'de_terminal', 'portable_ready')):
        raise RuntimeError('DE release/portable evidence is not complete')
    if Path(item['de_build']).resolve() != DE_BUILD.resolve():
        raise RuntimeError('Release belongs to another DE attempt')
    package = Path(item['package_root']).resolve()
    manifest = Path(item.get('manifest', package / 'fpga/release/gray_DE_20261031/manifest.json'))
    archive = Path(item['zip'])
    if sha(archive) != item['zip_sha256'] or sha(manifest) != item['manifest_sha256']:
        raise RuntimeError('DE portable ZIP or manifest drift')
    # The default audit checks every packaged file, exact 327 sources, native
    # exit evidence, MAP/PLC, 10 SCF commands, and 33 existing CCR diagnostics.
    # It does not invoke PDS or create a route scope.
    from portable_de import audit
    details = audit(manifest, root=package)
    return dict(path=str(path), sha256=sha(path), manifest=str(manifest),
                zip=str(archive), zip_sha256=sha(archive), audit=details)


def preflight(release):
    """Fail immediately on the global native lock; never wait/queue behind DE."""
    if (FPGA / 'build/route_optimization/native_phase.lock').exists():
        raise RuntimeError('Existing native phase lock; leave DE untouched')
    candidate = ROOT / 'candidate'
    manifest, functional = functional_proof(candidate)
    released = release_proof(release)
    if (ROOT / 'native').exists():
        raise RuntimeError('G native directory exists; inspect it, do not relaunch')
    return candidate, manifest, functional, released


def main():
    """One explicit SYN/MAP evaluation; all physical claims remain pending."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='Run once after successful read-only preflight')
    parser.add_argument('--de-release-review', type=Path, default=DEFAULT_RELEASE)
    args = parser.parse_args()
    candidate, manifest, functional, released = preflight(args.de_release_review)
    if not args.run:
        print(json.dumps(dict(status='PREFLIGHT_PASSED_NOT_STARTED', candidate=str(candidate),
                              functional=functional, de_release=released, native_started=False), indent=2))
        return
    out = ROOT / 'native'; out.mkdir(exist_ok=False)
    (out / 'driver.py').write_bytes(Path(__file__).read_bytes())
    stop = out / 'stop_requested.json'
    names = ('build_video_system.py', 'map_postsyn_candidate.py', 'route_supervisor.py',
             'implementation_readiness.py', 'constraint_report.py', 'native_bitgen.py',
             'review_gray_candidates.py', 'combined_cdc_gate.py', 'combined_candidate_gate.py',
             'finalize_gray_verification.py', 'portable_de.py', 'portable_de_readiness.py')
    scripts = {n: sha(FPGA / 'scripts' / n) for n in names}
    (out / 'scripts.json').write_text(json.dumps(scripts, indent=2), encoding='utf-8')
    state = dict(status='PREPARING', driver_pid=os.getpid(), candidate=str(candidate),
        source_count=327, sources_sha256=functional['sources_sha256'], functional=functional,
        de_release=released, routing_started=False, bitstream_generated=False,
        live_rtl_modified=False, readiness_modified=False)

    def publish(status):
        state.update(status=status, updated_at=datetime.now().astimezone().isoformat())
        temporary = out / 'state.tmp'
        temporary.write_text(json.dumps(state, indent=2), encoding='utf-8')
        temporary.replace(out / 'state.json')

    def stage(name, command, marker):
        """Reuse bounded supervisors; reject any intervening source/tool drift."""
        if (FPGA / 'build/route_optimization/native_phase.lock').exists():
            raise RuntimeError('Native lock appeared before ' + name)
        if stop.exists() or any(sha(FPGA / 'scripts' / n) != h for n, h in scripts.items()):
            raise RuntimeError('Stop requested or native driver drift')
        if frozen_sources(candidate) != manifest or sha(Path(functional['path'])) != functional['sha256']:
            raise RuntimeError('Functional evidence changed')
        if sha(args.de_release_review) != released['sha256']:
            raise RuntimeError('DE release review changed')
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
                    state[name] = line[len(marker) + 1:].strip(); publish(name.upper())
            code = child.wait()
        state['active_wrapper_pid'] = None
        if code:
            raise RuntimeError(name + ' failed; see exact log')
        build = Path(state[name]); result = read(build / 'result.json')
        if result.get('native_exit') != 0 or result.get('errors') or not result.get('snapshot_intact'):
            raise RuntimeError(name + ' native evidence failed')
        if frozen_sources(build) != manifest:
            raise RuntimeError(name + ' source set differs from G')
        state[name + '_result_sha256'] = sha(build / 'result.json')
        return build

    try:
        syn = stage('synthesis', [sys.executable, '-B', str(FPGA / 'scripts/build_video_system.py'),
            '--rtl-snapshot', str(candidate / 'source'), '--stage', 'synthesize',
            '--overall-timeout-minutes', '45', '--pause-file', str(stop)], 'BOARD_START')
        # Existing map_postsyn_candidate enforces its own 900-second host bound.
        mapping = stage('mapping', [sys.executable, '-B', str(FPGA / 'scripts/map_postsyn_candidate.py'),
            '--build', str(syn), '--pause-file', str(stop)], 'POSTSYN_CANDIDATE')
        from review_gray_candidates import inspect
        from combined_cdc_gate import review_cdc
        from finalize_gray_verification import timing_summary
        baseline = read(FPGA / 'build/DE_optimization_20261031/native/state.json')
        if baseline.get('status') != 'FUNCTIONAL_SYN_MAP_VERIFIED_PRE_ROUTE':
            raise RuntimeError('DE SYN/MAP baseline is not complete')
        bsyn = Path(baseline['synthesis']); bmap = Path(baseline['mapping'])
        original = frozen_sources(FPGA / 'build/DE_optimization_20261031/candidate')
        if frozen_sources(bsyn) != original or frozen_sources(bmap) != original:
            raise RuntimeError('DE native comparison does not match the G parent')
        if sha(bsyn / 'result.json') != baseline['synthesis_result_sha256'] or sha(bmap / 'result.json') != baseline['mapping_result_sha256']:
            raise RuntimeError('DE native comparison result drift')
        base = inspect(bsyn, bmap); review = inspect(syn, mapping)
        if base['mapping_resources'] != {'LUT': 37592, 'FF': 41960, 'APM': 154, 'DRM': 71.5, 'Distributed RAM': 1275}:
            raise RuntimeError('Unexpected DE MAP resource baseline')
        gate = review['constraints']
        if gate['postsyn_constraint_gate']['command_count'] != 10 or gate['constraint_check']['diagnostic_counts'] != {'ConstraintEditor-2002': 33}:
            raise RuntimeError('Unexpected MAP constraints; retain new diagnostics for review')
        review_cdc(syn, mapping, out)
        # An evaluation cannot silently switch functional revisions while native
        # tools run, even if its own copied source stayed intact.
        _, final_functional = functional_proof(candidate)
        if final_functional != functional:
            raise RuntimeError('Functional review changed during native evaluation')
        timing = timing_summary(syn); btiming = timing_summary(bsyn)
        clocks = timing['estimated_setup_ns']; bclocks = btiming['estimated_setup_ns']
        if set(clocks) != set(bclocks):
            raise RuntimeError('Synthesis clock set differs from DE')
        # CE replication is a separate, mandatory netlist review. syn_maxfan is
        # only an optimization request and can never prove physical success.
        review.update(status='G_SYN_MAP_COMPLETE_NETLIST_REVIEW_REQUIRED',
            functional=functional, de_release=released, baseline_DE=dict(syn=str(bsyn), mapping=str(bmap)),
            baseline_DE_resources=base['mapping_resources'],
            delta_vs_DE={k:v-base['mapping_resources'][k] for k,v in review['mapping_resources'].items()},
            timing=timing, baseline_DE_timing=btiming,
            estimated_setup_delta_vs_DE={k:clocks[k]-bclocks[k] for k in clocks},
            clocks_with_negative_estimated_setup={k:v for k,v in clocks.items() if v < 0},
            ce_netlist_review=dict(status='REQUIRES_NETLIST_REVIEW',
                baseline_DE_ce_loads=dict(geometry_shadow=608, geometry_active=736,
                                          references_shadow=351, references_active=479),
                required='Locate qualified write/commit logic and all duplicated branches in actual SYN VM; count each CE fanout and aggregate consumers; compare exact DE VM. Do not infer replication from attributes or lower total LUT.'),
            routing_started=False, routed_timing_verified=False, live_rtl_modified=False,
            readiness_modified=False, bitstream_generated=False, automatically_promoted=False)
        (ROOT / 'native_review.json').write_text(json.dumps(review, indent=2), encoding='utf-8')
        state.update(resources=review['mapping_resources'], review=str(ROOT / 'native_review.json'),
                     ce_netlist_review='REQUIRES_NETLIST_REVIEW')
        publish('SYN_MAP_COMPLETE_NETLIST_REVIEW_REQUIRED')
    except Exception as error:
        state['error'] = str(error); publish('FAILED'); raise


if __name__ == '__main__':
    main()
