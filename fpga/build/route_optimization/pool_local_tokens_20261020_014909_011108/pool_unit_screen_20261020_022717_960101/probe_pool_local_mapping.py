"""Screen proof-checked slot-local token flags using actual RAW-pool capacity.

Use the installed ADS settings already documented in the regional flow.
This SYN-only probe adds no latency, physical constraints or bitstream steps.
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


def diagnostic_pool(text):
    """Set both isolated defaults to the board's three RAW-pool transactions."""
    marker = 'parameter integer TXNS=8,'
    if text.count(marker) != 1:
        raise ValueError('Unexpected transaction parameter')
    return text.replace(marker, 'parameter integer TXNS=3,')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--regression', type=Path, required=True)
    parser.add_argument('--pause-file', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate,proof,regression = [x.resolve() for x in (args.candidate,args.proof,args.regression)]
    if not all(x.is_relative_to(fpga/'build') for x in [candidate,proof,regression]):
        raise ValueError('Frozen FPGA paths required')
    checked = json.loads((proof/'result.json').read_text())
    if not all(checked.get(k) for k in ['passed','inputs_intact','all_response_bits_compared','mirror_checked_on_both_edges']):
        raise ValueError('Complete strict differential proof required')
    if any(sha(Path(p))!=h for p,h in checked['inputs'].items()):
        raise ValueError('Proof drift')
    reg = json.loads((regression/'result.json').read_text())
    target = candidate/'source/rtl/memory/frame_pool_bank.sv'
    if not reg.get('passed') or len(reg.get('tests',[]))!=20 or sha(regression/'source/frame_pool_bank.sv')!=sha(target):
        raise ValueError('Complete regression must bind the pool candidate')
    sources = dict(baseline=candidate/'original_frame_pool_bank.sv',candidate=target)
    if any(checked['inputs'].get(str(p))!=sha(p) for p in sources.values()):
        raise ValueError('Both source identities must be in strict proof')
    dependencies = [candidate/'source/rtl/memory'/n for n in ['frame_manager_pkg.sv','frame_manager_layout.vh']]
    inputs = {str(p):sha(p) for p in [*sources.values(),*dependencies,proof/'result.json',regression/'result.json']}
    run = candidate/datetime.now().strftime('pool_unit_screen_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    for name in ['probe_pool_local_mapping.py','route_supervisor.py']:
        shutil.copyfile(Path(__file__).with_name(name),run/name)
    result = dict(passed=False,inputs=inputs,proof=str(proof),regression=str(regression),
                  slots=3,transactions=3,routed=False,jobs=[])
    print('POOL_UNIT_SCREEN',run,flush=True)
    try:
        for label,path in sources.items():
            build = run/label
            build.mkdir()
            (build/'pool.sv').write_text(diagnostic_pool(path.read_text(encoding='utf-8')),encoding='utf-8')
            for dep in dependencies:
                shutil.copyfile(dep,build/dep.name)
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow = 'set_dir -impl_directory {'+build.as_posix()+'}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for name in ['frame_manager_pkg.sv','pool.sv']:
                flow += 'add_design {'+(build/name).as_posix()+'}\n'
            flow += 'add_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
            flow += 'compile -top_module frame_pool_bank -system_verilog\n'
            flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build/'flow.tcl').write_text(flow,encoding='utf-8')
            supervision = run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                '-file',str(build/'flow.tcl'),'-work_dir',str(build)],cwd=build,
                log_path=build/'syn.log',monitor_path=build/'synthesis_monitor.jsonl',
                timeout_seconds=1200,pause_path=args.pause_file)
            errors = re.findall(r'^E:.*',(build/'syn.log').read_text(errors='replace'),re.M)
            job = dict(label=label,supervision=supervision,errors=errors)
            result['jobs'].append(job)
            if supervision['status']!='COMPLETED' or errors:
                raise RuntimeError('Pool synthesis failed: '+label)
            report = build/'synthesize/frame_pool_bank.snr'
            text = report.read_text(errors='replace')
            resources = {k:int(re.search(pattern,text)[1]) for k,pattern in [
                ('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),
                ('controlsets',r'Number of unique control sets : (\d+)')]}
            result[label] = dict(resources=resources,report_sha256=sha(report),
                timing_rows=re.findall(r'^ clk\s+clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$',text,re.M))
            print(label,json.dumps(result[label]),flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(sha(Path(p))==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
        print('POOL_UNIT_RESULT',run,flush=True)


if __name__ == '__main__':
    main()
