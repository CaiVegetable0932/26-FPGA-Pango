"""Measure original/candidate UART parser synthesis under identical settings.

Use installed PDS 2022.2-SP6.4, PG2L100H-6/FBG676 and an 8 ns clock. This is
unit synthesis only; it cannot establish whole-board placement or timing.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    """Bind a passing difference proof, measure both tops, audit ended shells."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--proof',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    candidate=args.candidate.resolve();proof=args.proof.resolve()
    if not all(p.is_relative_to(fpga/'build') for p in (candidate,proof)):raise ValueError('Frozen FPGA inputs required')
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    checked=json.loads((proof/'result.json').read_text())
    if not all(checked.get(k) for k in ('passed','cycle_equivalent','inputs_intact')):raise ValueError('Passing proof required')
    if any(sha(Path(p))!=h for p,h in checked['inputs'].items()):raise ValueError('Proof inputs changed')
    original=candidate/'original_uart_v2_parser.sv';source=candidate/'source/rtl/control/uart_v2_parser.sv'
    if any(checked['inputs'].get(str(p))!=sha(p) for p in (original,source)):raise ValueError('Proof source mismatch')
    run=candidate/datetime.now().strftime('uart_unit_probe_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(__file__,run/'probe_script.py')
    result=dict(passed=False,stage='unit_synthesis',board_timing_signoff=False,routed=False,
        official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf',
        pds_version='2022.2-SP6.4',proof=str(proof),inputs={str(p):sha(p) for p in (original,source)},jobs=[])
    print('UART_UNIT_PROBE',run,flush=True)
    try:
        for label,path in [('baseline',original),('candidate',source)]:
            build=run/label;build.mkdir();shutil.copyfile(path,build/'uart_v2_parser.sv')
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+build.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow+='add_design {'+(build/'uart_v2_parser.sv').as_posix()+'}\nadd_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
            flow+='compile -top_module uart_v2_parser -system_verilog\nsynthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build/'flow.tcl').write_text(flow)
            with (build/'syn.log').open('wb') as log:
                proc=subprocess.run(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(build/'flow.tcl'),'-work_dir',str(build)],cwd=build,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
            text=(build/'syn.log').read_text(errors='replace');errors=re.findall(r'^E:.*',text,re.M)
            # Natural parent exit is insufficient if a tool child was orphaned.
            # Preserve complete process identities; never terminate unrelated jobs.
            audit_command="Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'pds_shell.exe'} | Select-Object ProcessId,ParentProcessId,CreationDate,CommandLine | ConvertTo-Json -Compress"
            raw=subprocess.check_output(['powershell','-NoProfile','-Command',audit_command],creationflags=0x08000000)
            shells=json.loads(raw) if raw.strip() else []
            if isinstance(shells,dict):shells=[shells]
            owned=[r for r in shells if build.as_posix().lower() in (r.get('CommandLine') or '').replace('\\','/').lower()]
            audit=dict(at=datetime.now().astimezone().isoformat(),build=str(build),shells=shells,owned_residuals=owned,owned_residual_count=len(owned),forced_termination=False)
            (build/'after_processes.json').write_text(json.dumps(audit,indent=2)+'\n')
            job=dict(label=label,exit=proc.returncode,errors=errors,cleanup_audit=str(build/'after_processes.json'),residual_shells=len(owned));result['jobs'].append(job)
            if proc.returncode or errors or owned:raise RuntimeError('Unit SYN failed or left owned shells: '+label)
            report=build/'synthesize/uart_v2_parser.snr';s=report.read_text(errors='replace')
            resources={k:int(re.search(p,s)[1]) for k,p in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),('LUTRAM',r'LUTs as dram: (\d+)'),('controlsets',r'Number of unique control sets : (\d+)')]}
            resources['DRM']=float(re.search(r'Total DRM = ([\d.]+)',s)[1])
            timing=re.search(r'^ clk\s+clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$',s,re.M)
            if not timing:raise ValueError('Missing unit setup estimate')
            result[label]=dict(resources=resources,setup_estimate=dict(wns_ns=float(timing[1]),tns_ns=float(timing[2]),failing_endpoints=int(timing[3]),endpoints=int(timing[4])),report_sha256=sha(report))
            print(label,json.dumps(result[label]),flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(p))==h for p,h in result['inputs'].items())
        result['passed']=result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('RESULT',run,flush=True)


if __name__=='__main__':
    main()
