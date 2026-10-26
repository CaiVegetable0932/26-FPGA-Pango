"""Measure native minimum-control-set tradeoffs on the actual four-token bank.

ADS 2022.2-SP6.4 User Guide printed p20 documents min_controlset_size (default
2, positive integers): small CE/synchronous control groups move into D logic.
Identical RTL and 8ns constraints compare 2/8/16. This is an isolated resource
probe, never a routed board result or a substitute for min/max timing signoff.
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
    """Keep every native flow and output alongside the unchanged source bytes."""
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-build',type=Path,required=True)
    args=p.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    origin=args.source_build.resolve()
    if not origin.is_relative_to(fpga/'build'):
        raise ValueError('Use a frozen source build under fpga/build')
    manifest=json.loads((origin/'sources.json').read_text())
    names=['frame_manager_pkg.sv','frame_manager_layout.vh','frame_pool_bank.sv']
    for name in names:
        key='rtl/memory/'+name
        if hashlib.sha256((origin/'source'/key).read_bytes()).hexdigest()!=manifest[key]:
            raise ValueError('Frozen source changed: '+key)
    root=fpga/'build/full_integration_20261013'/datetime.now().strftime('controlset_probe_%Y%m%d_%H%M%S_%f')
    root.mkdir();shutil.copyfile(__file__,root/'probe_script.py')
    result=dict(passed=False,source_build=str(origin),board_timing_signoff=False,jobs=[])
    wrapper='''`include "frame_manager_layout.vh"
// Purpose: use the real board's four-token capacity while retaining dynamic
// commands and all responses. Both logical ports and clocks are identical.
module controlset_probe(input clk,reset_n,fabric_ready,display_boundary,
 input [`FM_CMD_BITS-1:0] cmd,output [`FM_RSP_BITS-1:0] rsp);
 frame_pool_bank #(.TXNS(4)) bank(clk,reset_n,fabric_ready,display_boundary,cmd,rsp);
endmodule
'''
    print('CONTROLSET_PROBE',root,flush=True)
    try:
        for minimum in (2,8,16):
            build=root/('minimum_'+str(minimum));build.mkdir()
            for name in names:shutil.copyfile(origin/'source/rtl/memory'/name,build/name)
            (build/'top.sv').write_text(wrapper)
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+build.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for name in ('frame_manager_pkg.sv','frame_pool_bank.sv','top.sv'):
                flow+='add_design {'+(build/name).as_posix()+'}\n'
            flow+='add_constraint {'+(build/'clock.fdc').as_posix()+'}\ncompile -top_module controlset_probe -system_verilog\n'
            flow+='synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2 -min_controlset_size '+str(minimum)+'\n'
            (build/'flow.tcl').write_text(flow)
            command=['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(build/'flow.tcl'),'-work_dir',str(build)]
            with (build/'console.log').open('wb') as log:
                child=subprocess.run(command,cwd=build,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
            errors=re.findall(r'^E:.*',(build/'console.log').read_text(errors='replace'),re.M)
            job=dict(minimum=minimum,exit=child.returncode,errors=errors,
                sources_intact=all(hashlib.sha256((build/n).read_bytes()).hexdigest()==manifest['rtl/memory/'+n] for n in names),
                flow_sha256=hashlib.sha256((build/'flow.tcl').read_bytes()).hexdigest())
            result['jobs'].append(job)
            if child.returncode or errors or not job['sources_intact']:
                raise RuntimeError('Native unit comparison failed')
            report=(build/'synthesize/controlset_probe.snr').read_text(errors='replace')
            for key,pattern in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),
                ('LUTRAM',r'LUTs as dram: (\d+)'),('controlsets',r'Number of unique control sets : (\d+)')]:
                job[key]=int(re.search(pattern,report)[1])
            print(json.dumps(job),flush=True)
        result['passed']=True
    finally:
        (root/'result.json').write_text(json.dumps(result,indent=2))
        print('RESULT',root,flush=True)


if __name__=='__main__':
    main()
