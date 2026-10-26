"""Measure identical native SYN settings for original and fixed-slice refill.

PDS 2022.2-SP6.4 ADS guide printed pp19-20 documents disable_io_insertion,
fanout_guide and resource_sharing. Unit results select alternatives only;
they are not routed board timing or throughput evidence.
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
    """Require the actual differential inputs before measuring two SYN jobs."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--differential',type=Path,required=True)
    parser.add_argument('--module',choices=('geometry_tile_refill','frame_pixel_writer'),
                        default='geometry_tile_refill',help='Source-bound unit to compare')
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):
        raise ValueError('Candidate must be in fpga/build')
    proof=json.loads((args.differential/'result.json').read_text(encoding='utf-8'))
    if not all(proof.get(k) for k in ('passed','cycle_equivalent','inputs_intact')):
        raise ValueError('Differential proof did not pass')
    module=args.module
    sources=dict(baseline=candidate/('original_'+module+'.sv'),
                 candidate=candidate/('source/rtl/memory/'+module+'.sv'))
    # Writer synthesis includes its exact source-bound packer dependency in
    # both jobs; no live RTL or tool default library may substitute for it.
    dependency=candidate/'source/rtl/memory/dma_pixel_pack.v' if module=='frame_pixel_writer' else None
    if dependency and proof['inputs'].get(str(dependency))!=hashlib.sha256(dependency.read_bytes()).hexdigest():
        raise ValueError('Packer proof input mismatch')
    for name,path in sources.items():
        if proof['inputs'].get(str(path))!=hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError('Proof input mismatch: '+name)
    run=candidate/datetime.now().strftime('unit_syn_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__,run/'probe_script.py')
    result=dict(passed=False,board_timing_signoff=False,jobs=[])
    print('PROBE',run,flush=True)
    try:
        for name,source in sources.items():
            build=run/name;build.mkdir()
            shutil.copyfile(source,build/(module+'.sv'))
            dependency_flow=''
            if dependency:
                shutil.copyfile(dependency,build/dependency.name)
                dependency_flow='add_design {'+(build/dependency.name).as_posix()+'}\n'
            # Wide unit ports are retained dynamically, without physical IO
            # insertion. Both jobs have identical 8ns and tool settings.
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n',encoding='ascii')
            flow=('set_dir -impl_directory {'+build.as_posix()+'}\n'
                'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
                'add_design {'+(build/(module+'.sv')).as_posix()+'}\n'+dependency_flow+
                'add_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
                'compile -top_module '+module+' -system_verilog\n'
                'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n')
            (build/'flow.tcl').write_text(flow,encoding='utf-8')
            command=['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(build/'flow.tcl'),'-work_dir',str(build)]
            with (build/'console.log').open('wb') as log:
                proc=subprocess.run(command,cwd=build,stdout=log,stderr=subprocess.STDOUT,timeout=600,creationflags=0x08000000)
            errors=re.findall(r'^E:.*',(build/'console.log').read_text(errors='replace'),re.M)
            job=dict(name=name,exit=proc.returncode,errors=errors,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
            result['jobs'].append(job)
            print(json.dumps(job),flush=True)
            if proc.returncode or errors:
                raise RuntimeError('Unit SYN failed: '+name)
        result['passed']=True
    finally:
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')


if __name__=='__main__':
    main()
