"""Freeze or measure paired fabric arbitration variants with identical ADS options.

Preparation is the default and launches no native process. The explicit --run
phase uses the shared supervisor lock and never touches another native build.
This is isolated synthesis only, not routed timing or a board resource claim.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil

from route_supervisor import run_supervised


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, help='Original frame_memory_fabric.sv before the RR change')
    parser.add_argument('--prepared', type=Path, help='Use this exact previously frozen paired probe')
    parser.add_argument('--run', action='store_true', help='Explicitly run native generation/SYN after coordination')
    parser.add_argument('--pause-file', type=Path)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    if args.prepared:
        run = args.prepared.resolve()
        if not run.is_relative_to(fpga / 'build'):
            parser.error('Prepared probe must be inside fpga/build')
        manifest = json.loads((run / 'probe.json').read_text(encoding='utf-8'))
    else:
        if not args.baseline or not args.baseline.is_file():
            parser.error('--baseline is required when preparing a new probe')
        run = fpga / 'build' / datetime.now().strftime('fabric_rr_probe_%Y%m%d_%H%M%S_%f')
        run.mkdir()
        names = ['frame_manager_pkg.sv', 'frame_pool_bank.sv', 'frame_manager.sv',
                 'ddr_native_dma.v', 'frame_memory_fabric.sv', 'frame_manager_layout.vh']
        manifest = dict(scope='isolated fabric default parameters N=6, BANK_TXNS=8, BOARD_CLIENT_LIMITS=0',
                        target='Logos2 PG2L100H FBG676 -6', period_ns=8,
                        resource_sharing=False, hardware_tested=False, routed=False, files={})
        for label in ['baseline', 'current']:
            directory = run / label
            source = directory / 'source'
            source.mkdir(parents=True)
            for name in names:
                origin = args.baseline if label == 'baseline' and name == 'frame_memory_fabric.sv' else fpga / 'rtl/memory' / name
                shutil.copyfile(origin, source / name)
            # The six unit dependencies and all options are frozen together.
            # Only the fabric RTL differs; no wrappers or interface tie-offs
            # may silently remove ownership, CRC, cancellation or readback work.
            clock = directory / 'unit.fdc'
            clock.write_text('create_clock -name unit_clk -period 8.000 [get_ports clk]\n')
            flow = 'set_dir -impl_directory {' + directory.as_posix() + '}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow += ''.join('add_design {' + (source / n).as_posix() + '}\n' for n in names if not n.endswith('.vh'))
            flow += 'add_constraint {' + clock.as_posix() + '}\n'
            flow += 'compile -top_module frame_memory_fabric -system_verilog -include_path [list {' + source.as_posix() + '}]\n'
            flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (directory / 'flow.tcl').write_text(flow)
            (directory / 'create.tcl').write_text('tcl2prj -tcl {' + (directory / 'flow.tcl').as_posix() + '}\n')
        shutil.copyfile(__file__, run / 'probe_script.py')
        shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), run / 'route_supervisor.py')
        manifest['files'] = {p.relative_to(run).as_posix(): sha(p) for p in run.rglob('*') if p.is_file()}
        for name in names:
            if name != 'frame_memory_fabric.sv':
                assert sha(run / 'baseline/source' / name) == sha(run / 'current/source' / name)
        (run / 'probe.json').write_text(json.dumps(manifest, indent=2))
    if not all(sha(run / n) == h for n, h in manifest['files'].items()):
        raise RuntimeError('Prepared probe input drift')
    print('FABRIC_RR_PROBE', run, flush=True)
    if not args.run:
        print('PREPARED_ONLY native_started=false', flush=True)
        return
    if (run / 'result.json').exists():
        raise RuntimeError('Preserve completed/failed evidence; prepare a fresh probe to rerun')
    shell = 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe'
    pause = args.pause_file or fpga / 'build/route_optimization/session_20261019/regional_stop_requested.json'
    result = dict(passed=False, variants=[], hardware_tested=False, routed=False)
    try:
        for label in ['baseline', 'current']:
            directory = run / label
            row = dict(variant=label, phases=[])
            result['variants'].append(row)
            for phase, command in [
                ('generate', [shell, '-file', str(directory / 'create.tcl'), '-work_dir', str(directory)]),
                ('synthesize', [shell, '-project', str(directory / 'flow.pds'), '-run', 'synthesize', '-work_dir', str(directory)])]:
                outcome = run_supervised(command, cwd=directory, log_path=directory / (phase + '.log'),
                    monitor_path=directory / (phase + '_monitor.jsonl'),
                    timeout_seconds=120 if phase == 'generate' else 600, pause_path=pause)
                row['phases'].append(dict(phase=phase, **outcome))
                log = (directory / (phase + '.log')).read_text(errors='replace')
                if outcome['status'] != 'COMPLETED' or outcome['returncode'] or re.search(r'^E:|Check license failed', log, re.M):
                    raise RuntimeError(label + ' ' + phase + ' did not complete')
            report = directory / 'synthesize/frame_memory_fabric.snr'
            contents = report.read_text(errors='replace')
            row['resources'] = {key: int(re.search(pattern, contents)[1]) for key, pattern in
                [('lut', r'Total LUTs: (\d+)'), ('ff', r'Total Registers: (\d+)')]}
            row['snr_sha256'] = sha(report)
        result['delta_current_minus_baseline'] = {key: result['variants'][1]['resources'][key] - result['variants'][0]['resources'][key] for key in ['lut', 'ff']}
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(sha(run / n) == h for n, h in manifest['files'].items())
        result['passed'] &= result['inputs_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2))
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
