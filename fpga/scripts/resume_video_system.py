"""Resume an immutable native board project, gate separate bitgen after STA."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from native_bitgen import generate_from_timed_database
from route_supervisor import run_supervised
from implementation_readiness import require_whole_design_ready


def verified_planning_help(path):
    """Bind module planning to installed, target-specific PDS CLI evidence.

    The PG2L100H option is absent from the older generic help invocation.
    Preserve the actual native help bytes instead of inferring another
    device/version's command spelling. The default never overrides planning.
    """
    if path is None:
        raise ValueError('Target-specific installed PNR help is required for module planning')
    payload = Path(path).read_bytes()
    content = payload.decode('utf-8', errors='replace')
    required = ('Version 2022.2-SP6.4 build 146967',
                '-planning_before_place Boolean_value (TRUE/FALSE)',
                'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676')
    if not all(item in content for item in required):
        raise ValueError('Installed PG2L100H planning option is unverified')
    return hashlib.sha256(payload).hexdigest()


def main():
    """Preserve earlier failed results; never modify the frozen source tree."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--pnr-timeout-minutes', type=int, default=60,
                        help='Native placement/routing allowance; does not relax clock constraints')
    parser.add_argument('--from-placement', action='store_true',
                        help='Use the completed native placement DB as documented by installed pnr help')
    parser.add_argument('--phase-timeout-minutes', type=int, default=60,
                        help='Positive external phase limit, independent of native action timeout')
    parser.add_argument('--pause-file', type=Path,
                        help='Stop this owned native phase when this request file appears')
    parser.add_argument('--control-chain-length', type=int, default=500,
                        help='Installed official CE/RS routing chain default')
    parser.add_argument('--placement-decongestion', type=int, default=1,
                        help='Installed placement expansion mode (0..9; guide recommends 0..4 above 70%% resources)')
    parser.add_argument('--placement-seed', type=int, default=7,
                        help='Native global placement seed; affects a new placement only')
    parser.add_argument('--mode', choices=('fast', 'normal', 'performance'), default='normal',
                        help='Installed native physical optimization mode')
    parser.add_argument('--cell-duplication', choices=('default', 'enabled', 'disabled'),
                        default='default',
                        help='Independent official placement duplication trial; default preserves the tool setting')
    # Installed User Guide pp111-112/p252 defines macro ordering. Apply this
    # only to a new placement; a reused PLC already fixes its macro positions.
    parser.add_argument('--macro-placement', choices=('Greedy', 'Global', 'Grouped', 'Close'),
                        help='Explicit early block placement policy; omission preserves native defaults')
    parser.add_argument('--planning-before-place', action='store_true',
                        help='Enable the installed PG2L100H module-planning option for a new placement')
    parser.add_argument('--installed-pnr-help', type=Path,
                        help='Frozen target-specific native help required with module planning')
    parser.add_argument('--dump-congestion', action='store_true',
                        help='Keep native per-iteration congestion nodes and conflicting net names')
    parser.add_argument('--congestion-iterations', type=int, default=200,
                        help='PG2L100H follows the official Logos router column (default 200)')
    # Installed User Guide p113/p252 and pnr help expose this independent
    # congestion-pin cost. Omit it by default so existing attempts retain the
    # native default 300; an explicit value changes no clock or STA gate.
    parser.add_argument('--pin-cost-increasing-speed', type=int,
                        help='Explicit native congestion-pin cost increment; native default is 300')
    args = parser.parse_args()
    # Resuming an old MAP must respect the same gate as a fresh full attempt.
    require_whole_design_ready()
    if args.planning_before_place != (args.installed_pnr_help is not None):
        parser.error('--planning-before-place and --installed-pnr-help must be supplied together')
    planning_help_sha256 = verified_planning_help(args.installed_pnr_help) if args.planning_before_place else None
    if not 0 <= args.pnr_timeout_minutes <= 180:
        parser.error('native action allowance must be 0..180 minutes (official 0 means no native limit)')
    if not 1 <= args.phase_timeout_minutes <= 1440:
        parser.error('host phase allowance must be 1..1440 minutes; unlimited waits are disabled')
    if not 1 <= args.control_chain_length <= 500:
        parser.error('control routing chain length must be 1..500')
    if not 0 <= args.placement_decongestion <= 9 or args.placement_seed < 1:
        parser.error('placement expansion must be 0..9 and placement seed must be positive')
    if args.congestion_iterations < 1:
        parser.error('congestion iterations must be positive')
    if args.pin_cost_increasing_speed is not None and args.pin_cost_increasing_speed <= 0:
        parser.error('explicit congestion-pin cost must be positive; PDS validates supported values')
    if args.from_placement and (args.placement_decongestion != 1 or args.placement_seed != 7
                               or args.cell_duplication != 'default' or args.macro_placement is not None
                               or args.planning_before_place):
        parser.error('new placement options require starting from the mapped DB, without --from-placement')
    fpga = Path(__file__).resolve().parents[1]
    run = args.build.resolve()
    if not run.is_relative_to(fpga / 'build') or not (run / 'flow.pds').is_file():
        raise ValueError('an existing FPGA native board project is required')
    # Native projects/checkpoints are not concurrently writable. Query process
    # metadata with constant PowerShell text and compare the path in Python;
    # user/path content is never interpolated into executable shell code.
    inventory = subprocess.run(['powershell', '-NoProfile', '-Command',
        "Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'pds_shell.exe'} | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"],
        capture_output=True, text=True, check=True, creationflags=0x08000000)
    rows = json.loads(inventory.stdout) if inventory.stdout.strip() else []
    if isinstance(rows, dict):
        rows = [rows]
    prefix = run.as_posix().lower()+'/'
    if any(prefix in (row.get('CommandLine') or '').replace('\\', '/').lower() for row in rows):
        raise ValueError('native project is still running; resume only after its processes finish')
    sources = json.loads((run / 'sources.json').read_text(encoding='utf-8'))
    intact = lambda: all(hashlib.sha256((run / 'source' / n).read_bytes()).hexdigest() == h for n, h in sources.items())
    if not intact():
        raise ValueError('native frozen source hash changed')
    evidence = run / datetime.now().strftime('resume_%Y%m%d_%H%M%S_%f')
    evidence.mkdir()
    if (run / 'result.json').exists():
        shutil.copyfile(run / 'result.json', evidence / 'prior_result.json')
    shutil.copyfile(Path(__file__), evidence / 'resume_script.py')
    shutil.copyfile(run / 'flow.pds', evidence / 'prior_project.pds')
    shutil.copyfile(Path(__file__).with_name('native_bitgen.py'), evidence / 'native_bitgen.py')
    # Freeze supervision logic as well as native commands for reproducibility.
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), evidence / 'route_supervisor.py')
    # Freeze the exact capability evidence alongside the generated flow. A
    # reused placement cannot be replanned, and no active project is modified.
    if args.planning_before_place:
        shutil.copyfile(args.installed_pnr_help, evidence / 'installed_pnr_help.log')
        if verified_planning_help(evidence / 'installed_pnr_help.log') != planning_help_sha256:
            raise ValueError('Planning help changed while freezing evidence')
    # Physical outputs are mutable across retries. Retain the failed database,
    # utilization/clock reports and native diagnostic files before the next
    # attempt replaces them; all evidence stays inside the FPGA build tree.
    previous_physical = evidence / 'previous_physical'
    previous_physical.mkdir()
    for old in (run / 'place_route').glob('*'):
        if old.is_file():
            shutil.copyfile(old, previous_physical / old.name)
        elif old.name in ('CongestionPlot', 'CongestionNetInfo'):
            shutil.copytree(old, previous_physical / old.name)
    shell = 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe'
    mapped = run / 'device_map/pango_video_system_map.adf'
    physical = run / 'device_map/pango_video_system.pcf'
    routed = run / 'place_route/pango_video_system_pnr.adf'
    if not mapped.is_file() or not physical.is_file():
        raise ValueError('a completed mapped native checkpoint is required')
    placement = run / 'place_route/pango_video_system_plc.adf'
    if args.from_placement:
        if not placement.is_file():
            raise ValueError('completed native placement database is required')
        # Keep an immutable copy: the native output directory can rewrite its
        # usual placement filename while continuing the physical action.
        shutil.copyfile(placement, evidence / placement.name)
        placement = evidence / placement.name
        (evidence / 'placement_input.sha256').write_text(
            hashlib.sha256(placement.read_bytes()).hexdigest()+'  '+placement.name+'\n', encoding='ascii')
    report = run / 'report_timing/pango_video_system.rtr'
    result = {'stage': 'not_started', 'native_exit': None, 'errors': [], 'snapshot_intact': True,
              'internal_timing_met': False, 'full_function_release': False, 'hardware_tested': False,
              'programmed': False, 'external_timing_verified': False, 'download_approved': False,
              'resumed_project': str(run / 'flow.pds'), 'resume_evidence': str(evidence), 'native_runs': []}
    result['physical_options'] = {
        'from_placement': args.from_placement, 'placement_decongestion': args.placement_decongestion,
        'placement_seed': args.placement_seed, 'mode': args.mode,
        'control_chain_length': args.control_chain_length, 'dump_congestion': args.dump_congestion,
        'native_timeout_minutes': args.pnr_timeout_minutes,
        'host_timeout_minutes': args.phase_timeout_minutes,
        'cell_duplication': args.cell_duplication,
        'macro_placement': args.macro_placement,
        'planning_before_place': True if args.planning_before_place else None,
        'planning_help_sha256': planning_help_sha256,
        'congestion_iterations': args.congestion_iterations,
        'pin_cost_increasing_speed': args.pin_cost_increasing_speed,
    }
    try:
        for phase in ('place_route', 'report_timing', 'gen_bit_stream'):
            # Describe the phase actually attempted, including an early pause.
            result['stage']=phase
            # Explicit input_db_file/force_to_run are documented by this exact
            # installed version. A standalone action avoids re-running compile
            # and synthesis; Python gates bitgen only after the NEW STA returns.
            print('RESUME', phase, run, flush=True)
            log_path = evidence / (phase+'.log')
            if phase == 'gen_bit_stream':
                child = generate_from_timed_database(run, shell, log_path)
            else:
                # Preserve the original RTL/IP registrations and constraint
                # order. The DDR IDF carries its fixed PHY/SERDES placement
                # context; a bare DB+user-FDC project loses that IP context.
                # No compile/synthesis command is included in this prefix.
                flow = (run / 'flow.tcl').read_text(encoding='utf-8').split('\ncompile ', 1)[0]+'\n'
                # Project-mode PnR automatically consumes dev_map's native PCF
                # (IO and fixed PHY sites). An explicit-DB project must also
                # register that generated physical dependency.
                flow += f'add_constraint {{{physical.as_posix()}}}\n'
                if phase == 'place_route':
                    # Version-matched guide pp111-118: placement expansion and
                    # seeds affect placement; the dump exposes conflicting nets.
                    # The p117 device exception says single-thread PG2L100H
                    # follows Logos general/router defaults, hence limit 200.
                    flow += (f'pnr -force_to_run -input_db_file {{{mapped.as_posix()}}}'
                             f' -action_timeout {args.pnr_timeout_minutes}'
                             f' -max_ctrl_chain_length {args.control_chain_length}'
                             f' -plc_decongestion {args.placement_decongestion}'
                             f' -gplace_seed {args.placement_seed} -mode {args.mode}'
                             f' -congest_overlap_limit {args.congestion_iterations}')
                    # Installed User Guide pp112/118 and native pnr help expose
                    # this placement optimization. A disabled trial may reduce
                    # replication pressure but worsen timing; keep every STA
                    # gate and preserve the default unless explicitly selected.
                    if args.cell_duplication != 'default':
                        flow += ' -dc_duplication '+('TRUE' if args.cell_duplication == 'enabled' else 'FALSE')
                    if args.macro_placement is not None:
                        flow += ' -early_block_placement '+args.macro_placement
                    # Installed User Guide p112 and target-specific help define
                    # module planning. Preserve all timing/STA/bitgen gates.
                    if args.planning_before_place:
                        flow += ' -planning_before_place TRUE'
                    if args.dump_congestion:
                        flow += ' -dump_router_congestion_plot TRUE'
                    # Adjust only the documented congestion penalty when a
                    # measured slow route requires it. Timing weight and all
                    # constraints are preserved; min/max remains mandatory.
                    if args.pin_cost_increasing_speed is not None:
                        flow += f' -pin_cost_increasing_speed {args.pin_cost_increasing_speed}'
                    flow += '\n'
                    if args.from_placement:
                        # input_place_db_file is the installed tool's explicit
                        # physical-checkpoint input, not an RTL/timing shortcut.
                        flow = flow.rstrip('\n')+f' -input_place_db_file {{{placement.as_posix()}}}\n'
                else:
                    flow += f'report_timing -force_to_run -input_db_file {{{routed.as_posix()}}} -delay_type min_max -max_path 30 -report_exception TRUE\n'
                script = evidence / (phase+'.tcl')
                script.write_text(flow, encoding='utf-8')
                # The installed guide defines action_timeout in minutes, but
                # external supervision also owns the full PnR wall-time bound
                # and convergence stall policy. Keep all native files intact.
                supervised = run_supervised(
                    [shell, '-file', str(script), '-work_dir', str(run)],
                    cwd=run, log_path=log_path,
                    timeout_seconds=args.phase_timeout_minutes*60,
                    monitor_path=evidence/(phase+'_monitor.jsonl'),
                    watch_stall=phase == 'place_route', pause_path=args.pause_file)
                child = subprocess.CompletedProcess([], supervised['returncode'])
                if supervised['status'] != 'COMPLETED':
                    result['native_runs'].append(dict(phase=phase, **supervised))
                    result.update(native_exit=child.returncode,
                                  optimization_status=supervised['status'])
                    raise RuntimeError('native '+phase+' stopped: '+supervised['status'])
            output = (evidence / (phase+'.log')).read_text(errors='replace')
            errors = re.findall(r'^E:.*', output, re.M)
            result['native_runs'].append({'phase': phase, 'exit': child.returncode, 'errors': errors})
            result['native_exit'] = child.returncode
            result['errors'] += errors
            text = report.read_text(errors='replace') if report.is_file() else ''
            result['internal_timing_met'] = bool(re.search(r'^Design Summary\s*:\s*All Constraints Met\.', text, re.M))
            if (child.returncode or errors or not intact() or
                    (phase != 'place_route' and not result['internal_timing_met'])):
                raise RuntimeError('native '+phase+' did not meet its gate')
        stream = run / 'generate_bitstream/pango_video_system.sbit'
        if not stream.is_file():
            raise RuntimeError('native bitstream absent after bitgen')
        result.update(bitstream=str(stream), bitstream_bytes=stream.stat().st_size,
                      bitstream_sha256=hashlib.sha256(stream.read_bytes()).hexdigest())
    finally:
        result['snapshot_intact'] = intact()
        (evidence / 'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        (run / 'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
