"""Freeze and synthesize PC control units using the installed PDS version.

The abstract-port probe measures logic only, never board timing or a release.
It uses the same ADS settings as the board and the shared native-process lock.
Official reference: installed ADS_User_Guide, compile/synthesize command flow.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil

from route_supervisor import run_supervised


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--top', choices=('pc_video_boot', 'pc_reference_upload'), default='pc_video_boot')
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    origin=(args.source or fpga).resolve()
    if not origin.is_relative_to(fpga):
        raise ValueError('Probe source must be in the FPGA development area')
    run=fpga/'build/affine_resource_probes'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    names=('pc_video_boot.sv','pc_reference_upload.sv','parameter_entity_guard.sv','uart_8n1.sv','uart_v2_parser.sv')
    hashes={}
    for name in names:
        content=(origin/'rtl/control'/name).read_text(encoding='utf-8')
        # The full board connects every retained entity; its mask is part of
        # the probe specialization, recorded independently from source hashes.
        if name in ('pc_video_boot.sv','pc_reference_upload.sv'):
            content=content.replace("ENTITY_MASK=16'h0200", "ENTITY_MASK=16'h0bfe")
        (source/name).write_text(content,encoding='utf-8')
        hashes[name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
    (run/'sources.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
    (run/'clock.fdc').write_text('create_clock -name control -period 8.0 [get_ports clk]\n')
    flow=f'set_dir -impl_directory {{{run.as_posix()}}}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
    flow+=''.join(f'add_design {{{(source/name).as_posix()}}}\n' for name in names)
    flow+=f'add_constraint {{{(run/"clock.fdc").as_posix()}}}\ncompile -top_module {args.top} -system_verilog\n'
    flow+='synthesize -ads -disable_io_insertion -rw_check_on_ram -resource_sharing false -fanout_guide 64 -selected_syn_tool_opt 2\n'
    (run/'flow.tcl').write_text(flow,encoding='utf-8');shutil.copyfile(__file__,run/'probe_script.py')
    print('CONTROL_PROBE',run,flush=True)
    status=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(run/'flow.tcl'),'-work_dir',str(run)],
                         cwd=run,log_path=run/'native.log',monitor_path=run/'monitor.jsonl',timeout_seconds=1200)
    log=(run/'native.log').read_text(errors='replace')
    errors=re.findall(r'^E:.*',log,re.M)
    report=run/'synthesize'/(args.top+'.snr')
    resources={}
    if report.exists():
        text=report.read_text(errors='replace')
        for key,pattern in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)')]:
            match=re.search(pattern,text)
            if match:resources[key]=int(match[1])
    intact=all(hashlib.sha256((source/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
    result=dict(top=args.top,source=str(origin),entity_mask='0x0bfe',supervision=status,errors=errors,resources=resources,
                passed=status['status']=='COMPLETED' and status['returncode']==0 and not errors and bool(resources) and intact,
                snapshot_intact=intact,hardware_tested=False,routed=False)
    (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result),flush=True)
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':
    main()
