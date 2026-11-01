"""Exercise GH2 portable guards using synthetic bytes; never call PDS or real scopes."""
import ast
from datetime import datetime
import json
from pathlib import Path
import shutil
from types import SimpleNamespace
from unittest.mock import patch

import portable_gh2 as portable
import portable_gh2_readiness as readiness
import resume_portable_gh2 as runner
from route_supervisor import stalled


def main():
    """Prove migration, tamper and one-attempt controls, not synthetic hardware."""
    fpga = Path(__file__).resolve().parents[1]
    output = fpga / 'build/gh2_release_preparation_20261101' / datetime.now().strftime('offline_%H%M%S_%f')
    repo = output / 'synthetic_repository'; inputs = repo / 'fpga/release/gray_GH2_20261101/inputs'
    proofdir = inputs.parent / 'evidence'; proofdir.mkdir(parents=True); inputs.mkdir()
    tests = []

    def reject(name, action):
        try:
            action()
        except (ValueError, FileExistsError):
            tests.append(name)
        else:
            raise AssertionError('Accepted invalid fixture: ' + name)

    for name in portable.INPUT_FILES:
        path = inputs / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('SYNTHETIC_OFFLINE_ONLY_' + name + '\n', encoding='utf-8')
    sources = {}
    for index in range(327):
        name = f'rtl/test{index}.sv'; path = inputs / 'source' / name
        path.parent.mkdir(parents=True, exist_ok=True); path.write_text('// fixture ' + name)
        sources[name] = portable.sha(path)
    portable.save(inputs / 'sources.json', sources); source_sha = portable.sha(inputs / 'sources.json')
    original = 'D:/Original/Frozen_GH2'
    (inputs / 'flow.tcl').write_text(f'set_dir -impl_directory {{{original}}}\n'
        'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
        f'add_design {{{original}/source/rtl/test0.sv}}\ncompile test\n', encoding='utf-8')
    (inputs / 'flow.pds').write_text(f'(_impl "{original}")\n', encoding='utf-8')
    portable.save(inputs / 'result.json', dict(stage='dev_map', native_exit=0, errors=[],
        snapshot_intact=True, placement_started=False))
    for name in portable.SCRIPT_FILES:
        path = repo / 'fpga/scripts' / name; path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fpga / 'scripts' / name, path); ast.parse(path.read_text(encoding='utf-8'))
    tests.append('syntax_all_runtime_scripts')
    functional = dict(passed=True, candidate_manifest_sha256=source_sha,
        full_video=dict(fresh_run=True, new_frames=3, repeated_frames=5, checked_pixels=16588800,
                        underflow=0, old_frame_and_drain_passed=True))
    portable.save(proofdir / 'functional_review.json', functional)
    postsyn = dict(passed=True, status='GH2_SYN_RAM_FSM_CE_VERIFIED_MAP_ALLOWED',
        sources_sha256=source_sha, vm_sha256=portable.sha(inputs / 'synthesize/pango_video_system_syn.vm'))
    portable.save(proofdir / 'postsyn_review.json', postsyn)
    final = dict(passed=True, status='GH2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE',
        candidate_sha256=source_sha, resources=portable.RESOURCES,
        functional={'sha256': portable.sha(proofdir / 'functional_review.json')}, mapping=original,
        terminal={'exit': {'returncode': 0}}, evidence_sha256={
            original + '/' + name: portable.sha(inputs / name) for name in portable.INPUT_FILES})
    portable.save(proofdir / 'final_review.json', final)
    m = dict(schema=1, kind='GH2_MAP_FRESH_PLACE_ROUTE', device=portable.DEVICE,
        run_options=portable.RUN_OPTIONS, inputs=inputs.relative_to(repo).as_posix(), original_build=original,
        source_count=327, source_manifest_sha256=source_sha, mapped_resources=portable.RESOURCES,
        proofs={key: (proofdir / (key + '.json')).relative_to(repo).as_posix()
                for key in ('final_review', 'functional_review', 'postsyn_review')})
    m['files'] = {p.relative_to(repo).as_posix(): portable.sha(p) for p in repo.rglob('*') if p.is_file()}
    manifest = inputs.parent / 'manifest.json'; portable.save(manifest, m)
    constraints = dict(constraint_check={'diagnostic_counts': {'ConstraintEditor-2002': 33}},
                       postsyn_constraint_gate={'command_count': 10})
    # Only native-report parsers and expected source identity use synthetic
    # substitutes. Actual package auditing retains the full native readers.
    with patch.object(portable, 'SOURCE_SHA', source_sha), \
         patch.object(portable, 'require_mapped_lut_budget', return_value={'total_lut': 37334}), \
         patch.object(portable, 'require_native_constraints', return_value=constraints):
        assert portable.audit(manifest, repo)['passed']; tests.append('complete_offline_closure')
        leaf = inputs / 'source/rtl/test0.sv'; saved = leaf.read_bytes(); leaf.write_text('drift')
        reject('source_tamper', lambda: portable.audit(manifest, repo)); leaf.write_bytes(saved)
        name = 'fpga/scripts/resume_portable_gh2.py'; digest = m['files'].pop(name); portable.save(manifest, m)
        reject('missing_runtime_binding', lambda: portable.audit(manifest, repo))
        m['files'][name] = digest; portable.save(manifest, m)
        (inputs / 'unbound.txt').write_text('unexpected')
        reject('unbound_sidecar', lambda: portable.audit(manifest, repo)); (inputs / 'unbound.txt').unlink()
        (inputs / 'place_route').mkdir()
        reject('imported_placement_directory', lambda: portable.audit(manifest, repo)); (inputs / 'place_route').rmdir()
        m['run_options'] = dict(portable.RUN_OPTIONS, from_placement=True); portable.save(manifest, m)
        reject('PLC_mode_option', lambda: portable.audit(manifest, repo))
        m['run_options'] = dict(portable.RUN_OPTIONS, pnr_timeout_minutes=0); portable.save(manifest, m)
        reject('unbounded_deadline', lambda: portable.audit(manifest, repo))
        m['run_options'] = portable.RUN_OPTIONS; portable.save(manifest, m)
        final['candidate_sha256'] = '0' * 64; portable.save(proofdir / 'final_review.json', final)
        name = m['proofs']['final_review']; m['files'][name] = portable.sha(proofdir / 'final_review.json')
        portable.save(manifest, m); reject('wrong_final_review_source', lambda: portable.audit(manifest, repo))
        final['candidate_sha256'] = source_sha; final['evidence_sha256'][original + '/device_map/pango_video_system_map.adf'] = '0' * 64
        portable.save(proofdir / 'final_review.json', final); m['files'][name] = portable.sha(proofdir / 'final_review.json')
        portable.save(manifest, m); reject('wrong_reviewed_MAP', lambda: portable.audit(manifest, repo))
    for bad in ('../escape', 'C:/external', 'C:relative', '\\server\\share', '/absolute'):
        reject('unsafe_manifest_path_' + bad, lambda bad=bad: portable.safe_path(repo, bad))
    target = output / 'relocated'
    refs = portable.relocate(inputs, target, original)
    assert refs == 1 and original not in (target / 'flow.tcl').read_text()
    assert portable.sha(target / 'device_map/pango_video_system_map.adf') == portable.sha(inputs / 'device_map/pango_video_system_map.adf')
    tests.append('relocation_only_preserves_native_DB')
    reject('target_overwrite', lambda: portable.relocate(inputs, target, original))
    pnr = runner.phase_tcl(target, 'place_route'); sta = runner.phase_tcl(target, 'report_timing')
    for token in ('-action_timeout 180', '-plc_decongestion 2', '-gplace_seed 7', '-dc_duplication TRUE',
                  '-planning_before_place TRUE', '-logic_optimize_lut6d_combing_strategy 3'):
        assert token in pnr
    assert all(token not in pnr + sta for token in ('input_place_db_file', 'gen_bit_stream', '\ncompile ', '\nsynthesize '))
    assert '-pin_cost_increasing_speed' not in pnr and '-delay_type min_max' in sta
    tests.append('fresh_PnR_exact_DE_options_and_minmax_only')
    reject('bitgen_phase', lambda: runner.phase_tcl(target, 'gen_bit_stream'))
    portable.claim_attempt(target)
    reject('repeat_attempt', lambda: portable.claim_attempt(target))
    options = portable.options_for_target(target, Path('C:/PDS/bin/pds_shell.exe'))
    scope = dict(id='synthetic', build=str(target), options=options,
        files={'sources.json': portable.sha(target / 'sources.json')}, external_files={})
    gate = dict(route_scope=scope, pre_route_review_complete=True, bitstream_generation_allowed=False)
    readiness.validate_route_scope(gate, target, SimpleNamespace(**options)); tests.append('exact_scope')
    reject('changed_scoped_seed', lambda: readiness.validate_route_scope(gate, target,
        SimpleNamespace(**dict(options, placement_seed=11))))
    foreign = target / 'foreign_script.py'; foreign.write_text('original')
    scope['external_files'][str(foreign)] = portable.sha(foreign); foreign.write_text('drift')
    reject('runtime_tool_drift', lambda: readiness.validate_route_scope(gate, target, SimpleNamespace(**options)))
    # The last STA phase must not escape the input/tool proof recheck merely
    # because its native timing summary passed. Exercise the shared end gate.
    with patch.object(runner, 'SOURCE_SHA', source_sha):
        native_hashes = {'device_map/pango_video_system_map.adf': portable.sha(target / 'device_map/pango_video_system_map.adf')}
        reject('end_of_STA_tool_drift', lambda: runner.require_immutable_inputs(
            target, sources, native_hashes, scope['external_files']))
        foreign.write_text('original')
        db = target / 'device_map/pango_video_system_map.adf'; saved_db = db.read_bytes(); db.write_text('drift')
        reject('end_of_STA_DB_drift', lambda: runner.require_immutable_inputs(
            target, sources, native_hashes, scope['external_files']))
        db.write_bytes(saved_db)
        runner.require_immutable_inputs(target, sources, native_hashes, scope['external_files'])
        tests.append('end_of_STA_all_bindings_intact')
    gatefile = output / 'scope.json'; portable.save(gatefile, gate)
    assert not readiness.close_route_scope('different', target / 'result.json', gatefile)
    assert readiness.close_route_scope('synthetic', target / 'result.json', gatefile)
    assert read_closed(gatefile); tests.append('scope_closes_only_matching_attempt')
    reject('wrong_installed_version', lambda: portable.validate_help('Version 2025.2'))
    reject('restricted_CIM_is_not_idle', lambda: cim_fixture(portable, '{}'))
    rounds = [dict(iteration=i, unrouted=n) for i, n in enumerate([7800, 7700, 7600, 7500, 7400, 7300, 7350, 7380, 7400, 7410, 7420])]
    assert stalled(rounds); tests.append('five_transition_stall_detected')
    report = dict(passed=True, tests=tests, count=len(tests), native_launched=False,
                  synthetic_only=True, runtime_sha256={n: portable.sha(fpga / 'scripts' / n) for n in portable.SCRIPT_FILES})
    portable.save(output / 'review.json', report)
    print(json.dumps(dict(passed=True, count=len(tests), review=str(output / 'review.json'))))


def read_closed(path):
    """Verify terminal closure without consulting any real readiness file."""
    value = json.loads(path.read_text(encoding='utf-8'))
    return value['whole_design_route_allowed'] is False and value['route_scope_status'] == 'CLOSED_AFTER_ATTEMPT'


def cim_fixture(module, payload):
    """Inject an incomplete query response rather than query live processes."""
    with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(stdout=payload)):
        return module.pds_processes()


if __name__ == '__main__':
    main()
