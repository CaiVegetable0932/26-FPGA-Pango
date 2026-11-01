"""Consume an isolated GH2 allowance: fresh MAP placement/routing, then min/max STA.

No PLC input, synthesis, bit generation or programming path exists here.
Success is raw physical evidence requiring external timing/constraint review.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
import sys
from types import SimpleNamespace

from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget, require_routed_lut_budget
from portable_gh2 import (FPGA, RUN_OPTIONS, SOURCE_SHA, SCRIPT_FILES, idle, now,
    options_for_target, read, reject_physical_inputs, save, sha, validate_help)
from portable_gh2_readiness import close_route_scope, record_path, require_whole_design_ready
from route_supervisor import run_supervised


def phase_tcl(run, phase):
    """Use the reviewed registration prefix and explicit fresh MAP/routed DB.

    PDS 2022.2-SP6.4 User Guide pp111-119/251-252 and target help describe
    these options. The board reference binds Logos2 PG2L100H/-6/FBG676.
    Keep DDR IDF context and native PCF; a bare DB loses PHY fixed sites.
    """
    flow = (run / 'flow.tcl').read_text(encoding='utf-8').split('\ncompile ', 1)[0] + '\n'
    for line in flow.splitlines():
        if line.strip() and not line.lstrip().startswith('#') and not re.match(
                r'^(?:set_dir|set_arch|add_design|add_constraint)\s', line):
            raise ValueError('Unexpected executable command in project prefix')
    if '-input_place_db_file' in flow:
        raise ValueError('Placement input forbidden')
    flow += f'add_constraint {{{(run / "device_map/pango_video_system.pcf").as_posix()}}}\n'
    if phase == 'place_route':
        flow += (f'pnr -force_to_run -input_db_file {{{(run / "device_map/pango_video_system_map.adf").as_posix()}}}'
            ' -action_timeout 180 -max_ctrl_chain_length 500 -mode normal -congest_overlap_limit 200'
            ' -plc_decongestion 2 -gplace_seed 7 -dc_duplication TRUE -planning_before_place TRUE'
            ' -dump_router_congestion_plot TRUE -logic_optimize_enable TRUE'
            ' -logic_optimize_lut6d_combing_strategy 3\n')
    elif phase == 'report_timing':
        flow += (f'report_timing -force_to_run -input_db_file {{{(run / "place_route/pango_video_system_pnr.adf").as_posix()}}}'
                 ' -delay_type min_max -max_path 30 -report_exception TRUE\n')
    else:
        raise ValueError('Only PnR and min/max STA are allowed')
    return flow


def preflight(run):
    """Check the one exact destination allowance; no native commands executed."""
    run = run.resolve()
    if not run.is_relative_to((FPGA / 'build/portable_gh2').resolve()):
        raise ValueError('Build is outside the GH2 destination directory')
    saved = read(record_path())
    options = saved['route_scope']['options']
    expected = options_for_target(run, Path(options['pds_shell']))
    if options != expected or any(options.get(k) != v for k, v in RUN_OPTIONS.items()):
        raise ValueError('Unreviewed physical option or deadline')
    gate = require_whole_design_ready(run, SimpleNamespace(**options))
    if (run / 'runner_claim.json').exists() or (run / 'stop_requested.json').exists():
        raise ValueError('Runner consumed or stop request present')
    if (FPGA / 'build/route_optimization/native_phase.lock').exists():
        raise ValueError('Global native lock exists')
    reject_physical_inputs(run)
    if sha(run / 'sources.json') != SOURCE_SHA:
        raise ValueError('Wrong frozen source manifest')
    validate_help(Path(options['installed_pnr_help']).read_text(errors='replace'))
    phase_tcl(run, 'place_route'); phase_tcl(run, 'report_timing')
    constraints = require_native_constraints(run)
    if (constraints['constraint_check']['diagnostic_counts'] != {'ConstraintEditor-2002': 33}
            or constraints['postsyn_constraint_gate']['command_count'] != 10):
        raise ValueError('Pre-route constraint diagnostics changed')
    lut = require_mapped_lut_budget(run)
    if lut['total_lut'] != 37334:
        raise ValueError('Wrong GH2 mapped revision')
    return gate, options


def frozen_source_intact(run, sources):
    """Recheck all 327 inputs, including untouched IP/CDC/clock dependencies."""
    return (sha(run / 'sources.json') == SOURCE_SHA and all(
        (run / 'source' / name).is_file() and sha(run / 'source' / name) == digest
        for name, digest in sources.items()))


def require_immutable_inputs(run, sources, input_hashes, external_files):
    """Check DBs/tools/proofs both before and after every native phase."""
    if not frozen_source_intact(run, sources):
        raise ValueError('Frozen sources changed')
    for name, digest in input_hashes.items():
        if not (run / name).is_file() or sha(run / name) != digest:
            raise ValueError('Frozen native input changed: ' + name)
    for name, digest in external_files.items():
        if not Path(name).is_file() or sha(name) != digest:
            raise ValueError('Bound tool/proof changed: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args(); run = args.build.resolve()
    gate, options = preflight(run)
    if args.check_only:
        print(json.dumps(dict(passed=True, source_count=327, mapped_lut=37334,
                              native_launched=False, from_placement=False)))
        return
    idle()
    # Direct execution cannot bypass the one-use runner claim, even when the
    # outer dispatch is unavailable. The independent scope is still required.
    with (run / 'runner_claim.json').open('x', encoding='utf-8') as stream:
        json.dump(dict(started_at=now(), scope_id=gate['route_scope']['id']), stream)
    evidence = run / datetime.now().strftime('resume_%Y%m%d_%H%M%S_%f')
    evidence.mkdir()
    print('GH2_EVENT ' + json.dumps(dict(resume=str(evidence), phase='preflight')), flush=True)
    save(run / 'active_resume.json', dict(resume=str(evidence), started_at=now()))
    shutil.copyfile(run / 'result.json', evidence / 'input_map_result.json')
    scripts = evidence / 'scripts'; scripts.mkdir()
    for name in SCRIPT_FILES:
        shutil.copyfile(FPGA / 'scripts' / name, scripts / name)
    save(evidence / 'scope.json', gate)
    sources = read(run / 'sources.json')
    inputs = ('device_map/pango_video_system_map.adf', 'device_map/pango_video_system.pcf',
              'synthesize/pango_video_system_syn.adf')
    input_hashes = {name: sha(run / name) for name in inputs}
    result = dict(status='RUNNING', stage='preflight', started_at=now(), native_exit=None,
        errors=[], snapshot_intact=True, native_runs=[], resume_evidence=str(evidence),
        build=str(run), physical_options=options, source_manifest_sha256=SOURCE_SHA,
        input_hashes=input_hashes, internal_timing_met=False, physical_signoff=False,
        external_timing_verified=False, hardware_tested=False, programmed=False,
        bitstream_generated=False, from_placement=False, partial_route_resumed=False)
    code = 1
    try:
        for phase in ('place_route', 'report_timing'):
            # Verify tools/shell/proofs between phases without treating native
            # changes to generated project metadata as source changes.
            require_immutable_inputs(run, sources, input_hashes, gate['route_scope']['external_files'])
            idle()
            result.update(stage=phase); save(evidence / 'result.json', result)
            print('GH2_EVENT ' + json.dumps(dict(resume=str(evidence), phase=phase)), flush=True)
            script = evidence / (phase + '.tcl'); script.write_text(phase_tcl(run, phase), encoding='utf-8')
            observed = run_supervised(
                [options['pds_shell'], '-file', str(script), '-work_dir', str(run)], cwd=run,
                log_path=evidence / (phase + '.log'), timeout_seconds=185 * 60,
                monitor_path=evidence / (phase + '_monitor.jsonl'), poll_seconds=30,
                watch_stall=phase == 'place_route', pause_path=Path(options['pause_file']),
                stall_window=5, stall_minimum=1000, stall_improvement=0.01, warmup_rounds=5,
                monitor_only=False)
            result['native_runs'].append(dict(phase=phase, **observed))
            result['native_exit'] = observed['returncode']
            output = (evidence / (phase + '.log')).read_text(errors='replace')
            errors = re.findall(r'^\s*E:.*', output, re.M); result['errors'].extend(errors)
            if observed['status'] != 'COMPLETED' or observed['returncode'] != 0 or errors:
                raise ValueError('Native ' + phase + ' failed: ' + observed['status'])
            result['native_constraint_gate'] = require_native_constraints(run)
            if phase == 'place_route':
                routed = run / 'place_route/pango_video_system_pnr.adf'
                if not routed.is_file() or not routed.stat().st_size:
                    raise ValueError('Native routed DB absent/empty')
                result['routed_db_sha256'] = sha(routed)
                result['routed_lut_gate'] = require_routed_lut_budget(run)
            else:
                report = run / 'report_timing/pango_video_system.rtr'
                if not report.is_file() or not report.stat().st_size:
                    raise ValueError('Real min/max timing report absent/empty')
                text = report.read_text(errors='replace')
                result['timing_report_sha256'] = sha(report)
                result['internal_timing_met'] = bool(re.search(
                    r'^Design Summary\s*:\s*All Constraints Met\.', text, re.M))
                if not result['internal_timing_met']:
                    raise ValueError('Real min/max timing did not meet native summary')
            require_immutable_inputs(run, sources, input_hashes, gate['route_scope']['external_files'])
            save(evidence / 'result.json', result)
        # Native summary is only admission to independent all-clock/CDC/DDR
        # hold and unconstrained-path review, not a hardware release signature.
        result['status'] = 'PNR_STA_COMPLETE_INDEPENDENT_REVIEW_REQUIRED'; code = 0
    except Exception as error:
        result.update(status='FAILED', failure=str(error))
    finally:
        result['snapshot_intact'] = frozen_source_intact(run, sources)
        try:
            require_immutable_inputs(run, sources, input_hashes, gate['route_scope']['external_files'])
            result['all_bound_inputs_intact'] = True
        except Exception as error:
            result.update(all_bound_inputs_intact=False, integrity_failure=str(error))
            result['status'] = 'BOUND_INPUT_DRIFT'; code = 1
        result['finished_at'] = now()
        try:
            from portable_gh2 import pds_processes
            rows = pds_processes()
            result['terminal_process_review'] = dict(query_visible=True, processes=rows,
                native_phase_lock_exists=(FPGA / 'build/route_optimization/native_phase.lock').exists())
            if rows or result['terminal_process_review']['native_phase_lock_exists']:
                result['status'] = 'TERMINAL_IDENTITY_REVIEW_REQUIRED'; code = 1
        except Exception as error:
            result['terminal_process_review'] = dict(query_visible=False, error=str(error)); code = 1
            result['status'] = 'TERMINAL_IDENTITY_REVIEW_REQUIRED'
        if not result['snapshot_intact']:
            result['status'] = 'SOURCE_DRIFT'; code = 1
        save(evidence / 'result.json', result)
        # Root result.json deliberately remains the imported MAP record. Only
        # this exact resume result plus launch_exit describes physical work.
        close_route_scope(gate['route_scope']['id'], evidence / 'result.json')
        print(json.dumps(dict(status=result['status'], resume=str(evidence), returncode=code)), flush=True)
    raise SystemExit(code)


if __name__ == '__main__':
    main()
