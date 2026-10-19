"""Synthesize the cycle-proven aligned unpack A/B with identical settings."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
from route_supervisor import run_supervised


def digest(path):
    """Bind the measured RTL to the strict six-run differential proof."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Use board aligned-row mode while retaining the production default."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--proof',type=Path,required=True)
    parser.add_argument('--pause-file',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    candidate,proof=args.candidate.resolve(),args.proof.resolve()
    if not all(p.is_relative_to(fpga/'build/route_optimization') for p in (candidate,proof)):
        raise ValueError('Frozen regional candidate and proof required')
    checked=json.loads((proof/'result.json').read_text(encoding='utf-8'))
    if not all(checked.get(k) for k in ('passed','cycle_equivalent','inputs_intact')):
        raise ValueError('Strict unpack proof must pass first')
    if any(digest(Path(p))!=h for p,h in checked['inputs'].items()):
        raise ValueError('Unpack proof input drift')
    sources=dict(baseline=candidate/'original_dma_byte_unpack.v',
                 candidate=candidate/'source/rtl/memory/dma_byte_unpack.v')
    if any(checked['inputs'].get(str(p))!=digest(p) for p in sources.values()):
        raise ValueError('Proof must bind both measured unpack implementations')
    run=candidate/datetime.now().strftime('unit_screen_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(__file__,run/'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'),run/'route_supervisor.py')
    result=dict(passed=False,routed=False,board_timing_signoff=False,proof=str(proof),
                inputs={str(p):digest(p) for p in sources.values()},clock_period_ns=8.0,jobs=[])
    try:
        for label,source in sources.items():
            build=run/label;build.mkdir()
            text=source.read_text(encoding='utf-8')
            if text.count('parameter ALIGNED_ROWS=0')!=1:
                raise ValueError('Unexpected unpack parameter default')
            (build/'unpack.v').write_text(text.replace('parameter ALIGNED_ROWS=0',
                'parameter ALIGNED_ROWS=1',1),encoding='utf-8')
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+build.as_posix()+'}\n'
            flow+='set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow+='add_design {'+(build/'unpack.v').as_posix()+'}\n'
            flow+='add_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
            flow+='compile -top_module dma_byte_unpack -system_verilog\n'
            flow+='synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build/'flow.tcl').write_text(flow)
            supervision=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                '-file',str(build/'flow.tcl'),'-work_dir',str(build)],cwd=build,
                log_path=build/'syn.log',timeout_seconds=1200,
                monitor_path=build/'synthesis_monitor.jsonl',pause_path=args.pause_file)
            errors=re.findall(r'^E:.*',(build/'syn.log').read_text(errors='replace'),re.M)
            result['jobs'].append(dict(label=label,supervision=supervision,error_count=len(errors),errors=errors[:10]))
            if supervision['status']!='COMPLETED' or errors:
                raise RuntimeError('Unpack unit synthesis did not complete: '+label)
            report=build/'synthesize/dma_byte_unpack.snr';text=report.read_text(errors='replace')
            metrics={k:int(re.search(pattern,text)[1]) for k,pattern in (
                ('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),
                ('controlsets',r'Number of unique control sets : (\d+)'))}
            metrics['DRM']=float(re.search(r'Total DRM = ([\d.]+)',text)[1])
            result[label]=dict(resources=metrics,report_sha256=digest(report))
            print(label,json.dumps(result[label]),flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(digest(Path(p))==h for p,h in result['inputs'].items())
        result['passed']=result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print('UNPACK_UNIT_SCREEN',run,flush=True)


if __name__=='__main__':main()
