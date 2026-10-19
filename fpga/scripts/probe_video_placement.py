"""Measure a documented placement alternative without treating it as routing.

PDS 2022.2-SP6.4 User Guide pp111-112 documents Global as distance-based early
macro placement; installed pnr help documents -early_block_placement and
-place_only. Retain all clocks, IP context, default packing and timing mode.
The input must be an isolated copy of a completed mapped video project.
The optional planning switch is supported by target-specific installed pnr help
and User Guide p112. Freeze that help evidence when requesting this switch.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from route_supervisor import run_supervised


def sha(path):
    """Bind measurements to immutable source and checkpoint bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Run placement only once; a separate reviewed route must follow."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--macro', choices=('Global', 'Greedy', 'Grouped', 'Close'),
                        default='Global')
    # Keep the historical defaults while permitting controlled same-MAP trials.
    # Limit expansion to the documented recommendation for high utilization.
    parser.add_argument('--decongestion', type=int, choices=range(5), default=1)
    parser.add_argument('--seed', type=int, default=11)
    parser.add_argument('--timeout-minutes', type=int, default=20)
    parser.add_argument('--planning-before-place', action='store_true',
                        help='Enable documented module planning; requires installed target help evidence')
    parser.add_argument('--installed-pnr-help', type=Path,
                        help='Saved PG2L100H pnr -help output for the exact installed version')
    args = parser.parse_args()
    if not 1 <= args.timeout_minutes <= 60:
        parser.error('placement screen budget must be 1..60 minutes')
    fpga = Path(__file__).resolve().parents[1]
    build = args.build.resolve()
    if not build.is_relative_to(fpga / 'build'):
        raise ValueError('placement evidence belongs under fpga/build')
    if (build / 'place_route').exists() or (build / 'placement_probe').exists():
        raise ValueError('require a fresh isolated mapped copy, not an active project')
    # Do not guess an option from another device or a generic help invocation.
    # The installed target-specific help must explicitly expose the switch.
    help_path = None
    if args.planning_before_place:
        if args.installed_pnr_help is None:
            raise ValueError('Target-specific native help is required for module planning')
        help_path = args.installed_pnr_help.resolve()
        help_text = help_path.read_text(errors='replace')
        if ('Version 2022.2-SP6.4 build 146967' not in help_text or
                '-planning_before_place Boolean_value (TRUE/FALSE)' not in help_text or
                'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676' not in help_text):
            raise ValueError('Installed target-specific planning option is unverified')
    manifest = json.loads((build / 'sources.json').read_text(encoding='utf-8'))
    intact = lambda: all(sha(build / 'source' / name) == digest
                         for name, digest in manifest.items())
    if len(manifest) != 290 or not intact():
        raise ValueError('the complete frozen video source set is required')
    # Guard process ownership before creating a mutable physical implementation.
    inventory = subprocess.run(['powershell', '-NoProfile', '-Command',
        "Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'pds_shell.exe'} | Select-Object CommandLine | ConvertTo-Json -Compress"],
        capture_output=True, text=True, check=True, creationflags=0x08000000)
    rows = json.loads(inventory.stdout) if inventory.stdout.strip() else []
    if isinstance(rows, dict):
        rows = [rows]
    prefix = build.as_posix().lower() + '/'
    if any(prefix in (row.get('CommandLine') or '').replace('\\', '/').lower()
           for row in rows):
        raise ValueError('project is already active')
    evidence = build / 'placement_probe'
    evidence.mkdir()
    shutil.copyfile(Path(__file__), evidence / 'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), evidence/'route_supervisor.py')
    if help_path is not None:
        shutil.copyfile(help_path, evidence / 'installed_pnr_help.log')
    checkpoints = {name: sha(build / 'device_map' / name) for name in
                   ('pango_video_system_map.adf', 'pango_video_system.pcf')}
    # Reuse the complete vendor IP/design/constraint registration in its order.
    # Keep all timing constraints; explicitly record the chosen seed and
    # expansion so the caller can compare one changed factor at a time. This
    # is a same-MAP policy comparison or a separately verified RTL candidate.
    flow = (build / 'flow.tcl').read_text(encoding='utf-8').split('\ncompile ', 1)[0] + '\n'
    flow += 'add_constraint {' + (build / 'device_map/pango_video_system.pcf').as_posix() + '}\n'
    flow += ('pnr -force_to_run -input_db_file {' +
             (build / 'device_map/pango_video_system_map.adf').as_posix() +
             '} -action_timeout 0 -max_ctrl_chain_length 500 -plc_decongestion ' +
             str(args.decongestion) + ' -gplace_seed ' + str(args.seed) +
             ' -mode normal -congest_overlap_limit 200'
             ' -early_block_placement ' + args.macro +
             (' -planning_before_place TRUE' if args.planning_before_place else '') +
             ' -place_only\n')
    script = evidence / 'place_only.tcl'
    script.write_text(flow, encoding='utf-8')
    shell = 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe'
    # Command-line spelling is shared with the established native resume driver.
    command = [shell, '-file', str(script), '-work_dir', str(build)]
    log_path = evidence / 'place_only.log'
    result = dict(stage='placement_only', routed=False, timing_signoff=False,
                  bitstream_generated=False, programmed=False, passed=False,
                  macro_policy=args.macro, placement_seed=args.seed,
                  placement_decongestion=args.decongestion, checkpoint_sha256=checkpoints,
                  planning_before_place_override=True if args.planning_before_place else None,
                  installed_help_sha256=sha(help_path) if help_path is not None else None,
                  source_count=len(manifest), command=command,
                  started_at=datetime.now().astimezone().isoformat())
    (evidence / 'started.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    try:
        print('PLACE_ONLY', build, args.macro, flush=True)
        # Placement-only screening shares the single native implementation slot.
        supervised = run_supervised(command, cwd=build, log_path=log_path,
            timeout_seconds=args.timeout_minutes*60, monitor_path=evidence/'placement_monitor.jsonl')
        child = subprocess.CompletedProcess(command, supervised['returncode'])
        result['supervision'] = supervised
        content = log_path.read_text(encoding='utf-8', errors='replace')
        result['native_exit'] = child.returncode
        result['errors'] = re.findall(r'^E:.*', content, re.M)
        result['snapshot_intact'] = intact()
        result['checkpoints_intact'] = all(sha(build / 'device_map' / name) == digest
                                          for name, digest in checkpoints.items())
        result['wirelength'] = re.findall(r'Wirelength after detailed placement is (\d+) and checksum is ([A-F0-9]+)', content)
        result['estimated_slack'] = re.findall(r'Worst slack is (-?\d+), TNS after placement is (-?\d+)', content)
        result['macro_messages'] = re.findall(r'^I: Process macros.*', content, re.M)
        placement = build / 'place_route/pango_video_system_plc.adf'
        result['placement_present'] = placement.is_file()
        if placement.is_file():
            result['placement_sha256'] = sha(placement)
        result['passed'] = (supervised['status'] == 'COMPLETED' and not result['errors'] and
                            result['snapshot_intact'] and result['checkpoints_intact'] and
                            result['placement_present'])
    finally:
        result['finished_at'] = datetime.now().astimezone().isoformat()
        (evidence / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(json.dumps(result), flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
