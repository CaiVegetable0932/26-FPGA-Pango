"""Audit GH2 offline; prepare once on Windows; run one fresh MAP-to-PnR/STA attempt.

The package has no input PLC. Exact 2022 target help is probed only by --prepare.
No action compiles RTL, synthesizes, creates bitstreams or programs hardware.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import subprocess
import sys
from types import SimpleNamespace

from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget
from portable_gh2_readiness import close_route_scope, record_path, validate_route_scope

FPGA = Path(__file__).resolve().parents[1]
DISPATCH = FPGA / 'build/portable_gh2/dispatch.json'
SOURCE_SHA = '65f8ad8e8fa86b5169c15d3ec3b0549a6ba938ce0544099515c1d3f1d564333f'
DEVICE = dict(family='Logos2', device='PG2L100H', speedgrade='-6', package='FBG676',
              pds_version='2022.2-SP6.4 build 146967')
RESOURCES = {'LUT': 37334, 'FF': 41380, 'APM': 154, 'DRM': 75.5, 'Distributed RAM': 1131}
# These preserve the actual DE placement options. Omission of pin-cost uses
# the documented default 300; this is not a new explicit pin-cost experiment.
RUN_OPTIONS = dict(stop_after_timing=True, monitor_only=False, from_placement=False,
    pnr_timeout_minutes=180, phase_timeout_minutes=185, placement_seed=7,
    placement_decongestion=2, mode='normal', control_chain_length=500,
    congestion_iterations=200, dump_congestion=True, logic_optimize='enabled',
    lut6d_strategy=3, cell_duplication='enabled', macro_placement=None,
    planning_before_place=True, pin_cost_increasing_speed=None)
INPUT_FILES = ('sources.json', 'flow.tcl', 'flow.pds', 'result.json', 'console.log',
    'device_map/pango_video_system_map.adf', 'device_map/pango_video_system.pcf',
    'device_map/pango_video_system.dmr', 'synthesize/pango_video_system_syn.adf',
    'synthesize/pango_video_system_syn.vm', 'synthesize/pango_video_system.snr',
    'constraint_check/constraint_check.ccr')
SCRIPT_FILES = ('portable_gh2.py', 'resume_portable_gh2.py', 'portable_gh2_readiness.py',
                'implementation_readiness.py', 'constraint_report.py', 'route_supervisor.py')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def now():
    return datetime.now().astimezone().isoformat()


def save(path, value):
    """Publish a complete record atomically for independent monitor readers."""
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.pending.json')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def safe_path(root, relative):
    """Reject absolute, drive-relative and escaping portable manifest entries."""
    if (not isinstance(relative, str) or not relative or Path(relative).is_absolute()
            or PureWindowsPath(relative).drive or '\\' in relative):
        raise ValueError('Expected normalized repository-relative package path')
    path = (Path(root) / relative).resolve()
    if not path.is_relative_to(Path(root).resolve()):
        raise ValueError('Path outside package: ' + relative)
    return path


def reject_physical_inputs(inputs):
    """A new layout cannot silently import placement, partial routes or timing."""
    for name in ('place_route', 'report_timing', 'generate_bitstream'):
        if (inputs / name).exists():
            raise ValueError('GH2 fresh MAP input must not include ' + name)
    for path in inputs.rglob('*'):
        if path.is_file() and (path.name.endswith(('_plc.adf', '_pnr.adf', '.sbit'))):
            raise ValueError('Physical artifact forbidden in input: ' + str(path))


def audit(manifest_path, root=None):
    """Validate exact GH2 input/proof closure without requiring PDS or old paths."""
    root = Path(root).resolve() if root is not None else FPGA.parent
    manifest_path = Path(manifest_path).resolve()
    if not manifest_path.is_relative_to(root):
        raise ValueError('Manifest must be inside package')
    m = read(manifest_path)
    if (m.get('schema') != 1 or m.get('kind') != 'GH2_MAP_FRESH_PLACE_ROUTE'
            or m.get('device') != DEVICE or m.get('run_options') != RUN_OPTIONS):
        raise ValueError('Unsupported GH2 package/device/options')
    inputs = safe_path(root, m['inputs'])
    if not inputs.is_relative_to(root / 'fpga/release'):
        raise ValueError('Inputs must be in the immutable release directory')
    files = m['files']
    for name, digest in files.items():
        path = safe_path(root, name)
        if not path.is_file() or sha(path) != digest:
            raise ValueError('Release integrity mismatch: ' + name)
    required = [(inputs / name).relative_to(root).as_posix() for name in INPUT_FILES]
    required += ['fpga/scripts/' + name for name in SCRIPT_FILES]
    if any(name not in files for name in required):
        raise ValueError('Manifest omits required input/tool')
    # No unmanifested sidecars may enter the working project via copytree.
    for path in inputs.rglob('*'):
        if path.is_file() and path.relative_to(root).as_posix() not in files:
            raise ValueError('Unbound input sidecar: ' + str(path))
    reject_physical_inputs(inputs)
    sources = read(inputs / 'sources.json')
    if len(sources) != 327 or m.get('source_count') != 327:
        raise ValueError('Wrong source closure')
    if sha(inputs / 'sources.json') != SOURCE_SHA or m.get('source_manifest_sha256') != SOURCE_SHA:
        raise ValueError('Wrong GH2 source manifest')
    for name, digest in sources.items():
        path = safe_path(inputs / 'source', name)
        if not path.is_file() or sha(path) != digest or files.get(path.relative_to(root).as_posix()) != digest:
            raise ValueError('Unbound/changed source: ' + name)
    proofs = m.get('proofs', {})
    if set(proofs) != {'final_review', 'functional_review', 'postsyn_review'}:
        raise ValueError('Three reviewed GH2 proofs are required')
    for path in proofs.values():
        if path not in files:
            raise ValueError('Unbound proof')
    final, functional, postsyn = (read(safe_path(root, proofs[k])) for k in
                                  ('final_review', 'functional_review', 'postsyn_review'))
    if (not final.get('passed') or final.get('status') !=
            'GH2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE'
            or final.get('candidate_sha256') != SOURCE_SHA
            or final.get('resources') != RESOURCES or m.get('mapped_resources') != RESOURCES):
        raise ValueError('Independent GH2 final review does not match')
    if (functional.get('passed') is not True or functional.get('candidate_manifest_sha256') != SOURCE_SHA
            or final['functional']['sha256'] != files[proofs['functional_review']]):
        raise ValueError('Functional evidence mismatch')
    video = functional['full_video']
    if any(video.get(k) != v for k, v in dict(fresh_run=True, new_frames=3, repeated_frames=5,
            checked_pixels=16588800, underflow=0, old_frame_and_drain_passed=True).items()):
        raise ValueError('Fresh full video evidence incomplete')
    if (postsyn.get('passed') is not True or postsyn.get('status') !=
            'GH2_SYN_RAM_FSM_CE_VERIFIED_MAP_ALLOWED' or postsyn.get('sources_sha256') != SOURCE_SHA
            or postsyn.get('vm_sha256') != sha(inputs / 'synthesize/pango_video_system_syn.vm')):
        raise ValueError('Combined RAM/FSM/CE proof mismatch')
    # Proof JSON keeps original paths as history; exact suffix and digest tie
    # the imported native DB/report bytes to that independently reviewed run.
    native_bound = final['evidence_sha256']
    original = m['original_build'].replace('\\', '/').rstrip('/')
    if final['mapping'].replace('\\', '/').rstrip('/') != original:
        raise ValueError('Final review belongs to a different MAP')
    for name in INPUT_FILES:
        if name in ('flow.tcl', 'flow.pds', 'console.log'):
            continue
        key = original + '/' + name
        matched = [v for k, v in native_bound.items() if k.replace('\\', '/') == key]
        if matched != [sha(inputs / name)]:
            # PCF is consumed by placement and is manifest-bound; original
            # final review did not hash it separately. All other DBs must bind.
            if name != 'device_map/pango_video_system.pcf':
                raise ValueError('Native input not bound to final review: ' + name)
    terminal = read(inputs / 'result.json')
    if (terminal.get('stage') != 'dev_map' or terminal.get('native_exit') != 0
            or terminal.get('errors') or terminal.get('snapshot_intact') is not True
            or terminal.get('placement_started') is not False):
        raise ValueError('Input MAP is not a completed pre-route job')
    if final['terminal']['exit'].get('returncode') != 0:
        raise ValueError('MAP driver exit not complete')
    resources = require_mapped_lut_budget(inputs)
    if resources['total_lut'] != RESOURCES['LUT']:
        raise ValueError('Wrong mapped resources')
    constraints = require_native_constraints(inputs)
    if (constraints['constraint_check']['diagnostic_counts'] != {'ConstraintEditor-2002': 33}
            or constraints['postsyn_constraint_gate']['command_count'] != 10):
        raise ValueError('Changed CCR or post-SYN SCF')
    return dict(passed=True, source_count=327, sources_sha256=SOURCE_SHA,
        mapped_resources=RESOURCES, inputs=str(inputs), manifest_sha256=sha(manifest_path),
        placement_reused=False, partial_route_resumed=False, physical_signoff=False,
        constraint_diagnostics=constraints['constraint_check']['diagnostic_counts'],
        postsyn_scf_count=10)


def relocate(inputs, target, original):
    """Relocate registrations only, retaining all RTL/IP/native DB bytes."""
    if target.exists():
        raise ValueError('Target already exists; do not overwrite or restart')
    if not original or any(c in str(original) + str(target) for c in '\r\n{}'):
        raise ValueError('Unsafe project root in Tcl braces')
    reject_physical_inputs(inputs)
    shutil.copytree(inputs, target)
    for name in ('flow.tcl', 'flow.pds'):
        path = target / name
        text = path.read_text(encoding='utf-8')
        text = text.replace(original.replace('\\', '/'), target.as_posix())
        text = text.replace(original.replace('/', '\\'), str(target))
        path.write_text(text, encoding='utf-8')
    prefix = (target / 'flow.tcl').read_text(encoding='utf-8').split('\ncompile ', 1)[0]
    refs = re.findall(r'(?m)^add_(?:design|constraint)\s+\{([^}]+)\}', prefix)
    if not refs:
        raise ValueError('Missing native source registrations')
    for name in refs:
        path = Path(name).resolve()
        if not path.is_file() or not path.is_relative_to((target / 'source').resolve()):
            raise ValueError('Relocated source absent/external: ' + name)
    if original.replace('\\', '/') in prefix.replace('\\', '/'):
        raise ValueError('Old project path survived relocation')
    return len(refs)


def options_for_target(target, shell):
    return dict(RUN_OPTIONS, pause_file=str(target / 'stop_requested.json'),
                installed_pnr_help=str(target / 'installed_pnr_help.log'), pds_shell=str(shell))


def pds_processes():
    """Require visible CIM identity; an unavailable query never proves idle."""
    query = """$ErrorActionPreference = 'Stop'
$self = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop
$native = @(Get-CimInstance Win32_Process -Filter "Name='pds_shell.exe' OR Name='pds.exe'" -ErrorAction Stop)
[pscustomobject]@{ provider_pid=$PID; provider=($self | Select-Object ProcessId,CreationDate,CommandLine);
processes=@($native | Select-Object ProcessId,CreationDate,CommandLine,ParentProcessId) } | ConvertTo-Json -Depth 4 -Compress
"""
    done = subprocess.run(['powershell', '-NoProfile', '-Command', query],
        capture_output=True, text=True, check=True, timeout=30, creationflags=0x08000000)
    data = json.loads(done.stdout) if done.stdout.strip() else {}
    provider = data.get('provider') or {}; rows = data.get('processes')
    if (provider.get('ProcessId') != data.get('provider_pid') or not data.get('provider_pid')
            or not provider.get('CreationDate') or not provider.get('CommandLine')
            or not isinstance(rows, list) or any(not isinstance(r, dict) or
              not all(r.get(k) for k in ('ProcessId', 'CreationDate', 'CommandLine')) for r in rows)):
        raise ValueError('CIM visibility incomplete; cannot establish idle state')
    return rows


def idle():
    if (FPGA / 'build/route_optimization/native_phase.lock').exists() or pds_processes():
        raise ValueError('Native process/lock exists; leave it untouched')


def validate_help(text):
    """Installed help must match the same target/version and all used knobs."""
    arch = 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676'
    required = (DEVICE['pds_version'], arch, '-input_db_file', '-action_timeout',
        '-max_ctrl_chain_length', '-congest_overlap_limit', '-plc_decongestion', '-gplace_seed',
        '-dc_duplication', '-planning_before_place', '-logic_optimize_enable',
        '-logic_optimize_lut6d_combing_strategy', '-dump_router_congestion_plot',
        'report_timing', '-delay_type', 'min_max')
    if any(value not in text for value in required) or re.search(r'^\s*E:', text, re.M):
        raise ValueError('Installed target/version/help not supported')


def claim_attempt(target, filename='attempt_claim.json'):
    """A persistent exclusive claim prevents retries after partial failure."""
    with (target / filename).open('x', encoding='utf-8') as stream:
        json.dump(dict(pid=os.getpid(), at=now()), stream)


def prepare(manifest_path, pds_root):
    """Probe only help on destination; freeze a single independent route scope."""
    review = audit(manifest_path)
    if os.name != 'nt':
        raise ValueError('Destination requires Windows')
    import psutil  # Mandatory creation-time monitoring dependency.
    if DISPATCH.exists() or record_path().exists():
        raise ValueError('Existing dispatch/scope; inspect rather than prepare again')
    idle()
    shell = pds_root.resolve() / 'bin/pds_shell.exe'
    if not shell.is_file() or any(c in str(shell) for c in '\r\n{}'):
        raise ValueError('Missing/unsafe PDS shell')
    root = DISPATCH.parent; root.mkdir(parents=True, exist_ok=True)
    claim_attempt(root, 'prepare_claim.json')
    m = read(manifest_path)
    target = root / datetime.now().strftime('route_%Y%m%d_%H%M%S_%f')
    refs = relocate(Path(review['inputs']), target, m['original_build'])
    # Only version-matched help is invoked here: no compile/SYN/MAP/PnR action.
    probe_script = target / 'installed_help.tcl'
    probe_script.write_text('set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
                            'help pnr\nhelp report_timing\n', encoding='utf-8')
    from route_supervisor import native_slot
    with native_slot():
        probe = subprocess.run([str(shell), '-file', str(probe_script), '-work_dir', str(target)],
            capture_output=True, timeout=120, creationflags=0x08000000)
    help_log = target / 'installed_pnr_help.log'; help_log.write_bytes(probe.stdout + probe.stderr)
    if probe.returncode:
        raise ValueError('Installed help probe failed; no route launched')
    validate_help(help_log.read_text(errors='replace'))
    # A new destination shell is bound by bytes; scope is independent of all
    # imported historical root configuration and its old route allowances.
    options = options_for_target(target, shell)
    names = [*INPUT_FILES, 'installed_pnr_help.log']
    names += ['source/' + name for name in read(target / 'sources.json')]
    external = {str(safe_path(FPGA.parent, name)): digest for name, digest in m['files'].items()
                if name.startswith('fpga/scripts/') or name in m['proofs'].values()}
    external.update({str(Path(manifest_path).resolve()): sha(manifest_path), str(shell): sha(shell)})
    scope = dict(id=target.name, build=str(target), options=options,
                 files={name: sha(target / name) for name in names}, external_files=external)
    gate = dict(design_complete=True, selected_source_simulation_passed=True,
        resource_and_constraints_reviewed=True, whole_design_route_allowed=True,
        pre_route_review_complete=True, bitstream_generation_allowed=False,
        user_gui_approval_required=False, route_scope=scope,
        route_scope_status='READY_FOR_ONE_BOUNDED_ATTEMPT',
        user_route_approval='2026-11-01 user requested GH2 cloud release for external bounded PnR/STA.')
    validate_route_scope(gate, target, SimpleNamespace(**options)); save(record_path(), gate)
    command = [sys.executable, '-B', str(FPGA / 'scripts/resume_portable_gh2.py'), '--build', str(target)]
    save(target / 'physical_review.json', dict(audit=review, scope=scope,
        source_reference_count=refs, physical_benefit_proven=False, bitstream_allowed=False))
    save(target / 'launch_command.json', command)
    try:
        checked = subprocess.run(command + ['--check-only'], capture_output=True, timeout=120,
                                 creationflags=0x08000000)
        (target / 'preflight.log').write_bytes(checked.stdout + checked.stderr)
        if checked.returncode:
            raise ValueError('Relocated preflight failed')
    except Exception:
        close_route_scope(scope['id'], target / 'preflight.log'); raise
    save(DISPATCH, dict(status='PREPARED', build=str(target), manifest=str(Path(manifest_path).resolve()),
        manifest_sha256=sha(manifest_path), command=command, prepared_at=now()))
    print('PREPARED', target, flush=True)


def launch():
    """Consume one prepared job; all children hidden, exact resume pointer published."""
    state = read(DISPATCH)
    if state['status'] != 'PREPARED':
        raise ValueError('Dispatch already consumed; no automatic retry')
    if sha(state['manifest']) != state['manifest_sha256']:
        raise ValueError('Prepared manifest changed')
    audit(state['manifest']); idle()
    target = Path(state['build'])
    subprocess.run(state['command'] + ['--check-only'], check=True, creationflags=0x08000000)
    claim_attempt(target)
    state.update(status='STARTING', wrapper_pid=os.getpid(), started_at=now()); save(DISPATCH, state)
    save(target / 'launch_started.json', dict(wrapper_pid=os.getpid(), started_at=now(), command=state['command']))
    env = os.environ.copy(); env.update(PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    code = None
    try:
        with (target / 'launch.log').open('x', encoding='utf-8') as log:
            child = subprocess.Popen(state['command'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', env=env, creationflags=0x08000000)
            state.update(status='RUNNING', resume_wrapper_pid=child.pid); save(DISPATCH, state)
            for line in child.stdout:
                log.write(line); log.flush(); print(line, end='', flush=True)
                if line.startswith('GH2_EVENT '):
                    event = json.loads(line[len('GH2_EVENT '):])
                    state.update({k: event[k] for k in ('resume', 'phase') if k in event})
                    save(DISPATCH, state)
            code = child.wait()
    except Exception as error:
        state['launch_error'] = str(error)
        # Do not kill/adopt a child on a bookkeeping exception. Its supervisor
        # owns native cleanup; the persistent dispatch prevents another launch.
        state['status'] = 'LAUNCH_OR_TRACKING_FAILED'; raise
    finally:
        ended = dict(returncode=code, ended_at=now(), launch_error=state.get('launch_error'))
        save(target / 'launch_exit.json', ended)
        if code is not None:
            state['status'] = 'COMPLETE_REQUIRES_PHYSICAL_REVIEW' if code == 0 else 'FAILED'
        state.update(ended); save(DISPATCH, state)
        scope_state = read(record_path())
        if scope_state.get('whole_design_route_allowed'):
            # Preserve the runner's exact resume result if it already closed
            # normally; outer launch failure still consumes an unclosed scope.
            close_route_scope(scope_state['route_scope']['id'], target / 'launch_exit.json')
    raise SystemExit(code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--audit', action='store_true'); action.add_argument('--prepare', action='store_true')
    action.add_argument('--run', action='store_true')
    parser.add_argument('--manifest', type=Path, default=FPGA / 'release/gray_GH2_20261101/manifest.json')
    parser.add_argument('--pds-root', type=Path)
    args = parser.parse_args()
    if args.run:
        launch()
    elif args.prepare:
        if args.pds_root is None:
            parser.error('--prepare requires --pds-root')
        prepare(args.manifest, args.pds_root)
    else:
        print(json.dumps(audit(args.manifest), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
