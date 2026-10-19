"""Compare original/local-enable PC boot synthesis on the installed device.

Use the same 8 ns clock, all dynamic ports and synthesis settings for both.
This unit screen measures mapping/control locality only, never routed signoff.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
from route_supervisor import run_supervised


def digest(path):
    """Hash immutable proof and source inputs before and after native jobs."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Require cycle proof before reserving the shared native synthesis slot."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--timeout-minutes', type=int, default=20)
    parser.add_argument('--pause-file', type=Path)
    args = parser.parse_args()
    if not 1 <= args.timeout_minutes <= 60:
        parser.error('unit synthesis allowance must be 1..60 minutes')
    fpga = Path(__file__).resolve().parents[1]
    candidate, proof = args.candidate.resolve(), args.proof.resolve()
    if not all(p.is_relative_to(fpga/'build') for p in (candidate, proof)):
        raise ValueError('Frozen FPGA candidate and proof are required')
    checked = json.loads((proof/'result.json').read_text(encoding='utf-8'))
    if not all(checked.get(k) for k in ('passed','cycle_equivalent','inputs_intact')):
        raise ValueError('Passing cycle-equivalence proof required')
    if any(digest(Path(p)) != h for p,h in checked['inputs'].items()):
        raise ValueError('Proof input drift')
    sources = dict(baseline=candidate/'original_pc_video_boot.sv',
                   candidate=candidate/'source/rtl/control/pc_video_boot.sv')
    if any(checked['inputs'].get(str(p)) != digest(p) for p in sources.values()):
        raise ValueError('The proof must bind both measured implementations')
    dependencies = [candidate/'source/rtl/control'/n
                    for n in ('uart_8n1.sv','uart_v2_parser.sv','parameter_entity_guard.sv')]
    run = candidate/datetime.now().strftime('unit_screen_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__, run/'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), run/'route_supervisor.py')
    inputs = {str(p): digest(p) for p in [*sources.values(),*dependencies]}
    result = dict(passed=False, routed=False, timing_signoff=False, jobs=[],
                  inputs=inputs, proof=str(proof), clock_period_ns=8.0)
    print('BOOT_UNIT_SCREEN', run, flush=True)
    try:
        for label, source in sources.items():
            build = run/label
            build.mkdir()
            shutil.copyfile(source, build/'pc_video_boot.sv')
            for p in dependencies:
                shutil.copyfile(p, build/p.name)
            fdc = build/'clock.fdc'
            fdc.write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow = 'set_dir -impl_directory {'+build.as_posix()+'}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for name in ['pc_video_boot.sv',*(p.name for p in dependencies)]:
                flow += 'add_design {'+(build/name).as_posix()+'}\n'
            flow += 'add_constraint {'+fdc.as_posix()+'}\n'
            flow += 'compile -top_module pc_video_boot -system_verilog\n'
            flow += ('synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram '
                     '-resource_sharing false -selected_syn_tool_opt 2\n')
            script = build/'flow.tcl'
            script.write_text(flow)
            supervised = run_supervised(
                ['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                 '-file',str(script),'-work_dir',str(build)],
                cwd=build, log_path=build/'syn.log', monitor_path=build/'synthesis_monitor.jsonl',
                timeout_seconds=args.timeout_minutes*60, pause_path=args.pause_file)
            errors = re.findall(r'^E:.*',(build/'syn.log').read_text(errors='replace'),re.M)
            result['jobs'].append(dict(label=label,supervision=supervised,errors=errors))
            if supervised['status'] != 'COMPLETED' or errors:
                raise RuntimeError('Native unit synthesis did not complete: '+label)
            report = build/'synthesize/pc_video_boot.snr'
            content = report.read_text(errors='replace')
            patterns = dict(LUT=r'Total LUTs: (\d+)', FF=r'Total Registers: (\d+)',
                            controlsets=r'Number of unique control sets : (\d+)',
                            LUTRAM=r'LUTs as dram: (\d+)')
            resources = {name:int(re.search(pattern,content)[1]) for name,pattern in patterns.items()}
            resources['DRM'] = float(re.search(r'Total DRM = ([\d.]+)',content)[1])
            result[label] = dict(resources=resources, report_sha256=digest(report))
            print(label,json.dumps(result[label]),flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(digest(Path(p)) == h for p,h in inputs.items())
        result['passed'] = result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print('RESULT',run,flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
