"""Compare a cycle-checked DMA selector with its byte-exact P12 baseline.

Installed ADS guide pp19-20 documents the common synthesis settings. The
board's seven clients, sixteen beats and verified writes are used for both
isolated tops. These measurements cannot establish routed board timing.
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
    """Bind the actual source/report bytes rather than a candidate label."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Gate native comparison on transport proof; audit shells after each job."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--timeout-minutes', type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.timeout_minutes <= 60:
        parser.error('unit synthesis budget must be 1..60 minutes')
    fpga = Path(__file__).resolve().parents[1]
    candidate, proof = args.candidate.resolve(), args.proof.resolve()
    if not all(p.is_relative_to(fpga / 'build') for p in (candidate, proof)):
        raise ValueError('Frozen FPGA inputs required')
    checked = json.loads((proof / 'result.json').read_text(encoding='utf-8'))
    if not all(checked.get(k) for k in ('passed', 'cycle_equivalent', 'inputs_intact')):
        raise ValueError('Passing transport proof required')
    if any(sha(Path(p)) != h for p, h in checked['inputs'].items()):
        raise ValueError('Proof input changed')
    sources = dict(baseline=candidate / 'original_ddr_native_dma.v',
                   candidate=candidate / 'source/rtl/memory/ddr_native_dma.v')
    if any(checked['inputs'].get(str(p)) != sha(p) for p in sources.values()):
        raise ValueError('Proof does not bind both DMA sources')
    run = candidate / datetime.now().strftime('owner_unit_probe_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__, run / 'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), run/'route_supervisor.py')
    result = dict(passed=False, routed=False, board_timing_signoff=False,
                  proof=str(proof), inputs={str(p): sha(p) for p in sources.values()}, jobs=[])
    print('OWNER_UNIT_PROBE', run, flush=True)
    try:
        for label, path in sources.items():
            build = run / label
            build.mkdir()
            text = path.read_text(encoding='utf-8')
            if text.count('parameter VERIFY_WRITES=0') != 1:
                raise ValueError('Unexpected verified-write parameter')
            # Only the isolated top defaults change; both match the actual
            # board configuration. Frozen production RTL remains untouched.
            (build / 'dma.v').write_text(text.replace('parameter VERIFY_WRITES=0',
                'parameter VERIFY_WRITES=1', 1), encoding='utf-8')
            (build / 'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow = 'set_dir -impl_directory {'+build.as_posix()+'}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow += 'add_design {'+(build / 'dma.v').as_posix()+'}\n'
            flow += 'add_constraint {'+(build / 'clock.fdc').as_posix()+'}\n'
            flow += 'compile -top_module ddr_native_dma -system_verilog\n'
            flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build / 'flow.tcl').write_text(flow, encoding='utf-8')
            # Both sides use the same bounded, exclusive native slot.
            supervised = run_supervised(
                ['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                 '-file',str(build/'flow.tcl'),'-work_dir',str(build)],
                cwd=build, log_path=build/'syn.log', timeout_seconds=args.timeout_minutes*60,
                monitor_path=build/'synthesis_monitor.jsonl')
            proc = subprocess.CompletedProcess([], supervised['returncode'])
            errors = re.findall(r'^E:.*', (build / 'syn.log').read_text(errors='replace'), re.M)
            # Natural completion must not leave an orphaned native child.
            # Record full identities and stop before starting another job if
            # a residual exists; no process is terminated by this probe.
            command = "Get-CimInstance Win32_Process -Filter \"Name='pds_shell.exe'\" | ForEach-Object { [pscustomobject]@{ProcessId=$_.ProcessId;ParentProcessId=$_.ParentProcessId;CreationDate=$_.CreationDate.ToString('o');CommandLine=$_.CommandLine} } | ConvertTo-Json -Depth 5 -Compress"
            raw = subprocess.check_output(['powershell', '-NoProfile', '-Command', command], creationflags=0x08000000)
            shells = json.loads(raw) if raw.strip() else []
            if isinstance(shells, dict):
                shells = [shells]
            owned = [p for p in shells if build.as_posix().lower() in (p.get('CommandLine') or '').replace('\\', '/').lower()]
            audit = dict(at=datetime.now().astimezone().isoformat(), shells=shells,
                         owned_residuals=owned, forced_termination=False)
            (build / 'after_processes.json').write_text(json.dumps(audit, indent=2)+'\n')
            result['jobs'].append(dict(label=label, exit=proc.returncode, errors=errors,
                                      residual_shells=len(owned), supervision=supervised))
            if supervised['status'] != 'COMPLETED' or errors or owned:
                raise RuntimeError('Synthesis failed or left owned processes: '+label)
            report = build / 'synthesize/ddr_native_dma.snr'
            s = report.read_text(errors='replace')
            resources = {k: int(re.search(pattern, s)[1]) for k, pattern in (
                ('LUT', r'Total LUTs: (\d+)'), ('FF', r'Total Registers: (\d+)'),
                ('LUTRAM', r'LUTs as dram: (\d+)'), ('controlsets', r'Number of unique control sets : (\d+)'))}
            resources['DRM'] = float(re.search(r'Total DRM = ([\d.]+)', s)[1])
            timing = re.findall(r'^ clk\s+clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$', s, re.M)
            if not timing:
                raise ValueError('Missing native unit timing estimate')
            result[label] = dict(resources=resources, timing_rows=timing, report_sha256=sha(report))
            print(label, json.dumps(result[label]), flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(sha(Path(p)) == h for p, h in result['inputs'].items())
        result['passed'] = result['passed'] and result['inputs_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print('RESULT', run, flush=True)


if __name__ == '__main__':
    main()
