"""Exhaustively compare frozen DMA selectors and measure native unit resources.

SYN uses identical dynamic ports, seven clients, sixteen beats, verified writes,
and an 8ns clock on PG2L100H-6/FBG676 under installed PDS 2022.2-SP6.4. This
isolated measurement cannot establish full-board timing or transport correctness.
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
    """Retain actual source bytes, exhaustive logs and both native reports."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):raise ValueError('Frozen FPGA candidate required')
    source=candidate/'source/rtl/memory/ddr_native_dma.v';baseline=candidate/'arbiter_baseline_dma.v';fixture=fpga/'sim/tb_dma_arbiter_differential.sv'
    run=candidate/datetime.now().strftime('arbiter_probe_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(__file__,run/'probe_script.py');shutil.copyfile(fixture,run/fixture.name)
    (run/'candidate.v').write_bytes(source.read_bytes())
    (run/'baseline.v').write_text(baseline.read_text().replace('module ddr_native_dma #(','module baseline_arbiter_dma #(',1))
    result=dict(passed=False,cycle_equivalent=False,scope='Exact combinational selector outputs for all legal rr/quota/eligible/urgent combinations; full DMA transport proof is separate',board_timing_signoff=False,inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (source,baseline,fixture)},jobs=[])
    print('ARBITER_PROBE',run,flush=True)
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'

    def execute(label,command,cwd):
        """Require both native exit status and readable explicit success markers."""
        with (cwd/(label+'.log')).open('wb') as log:
            child=subprocess.run(command,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
        text=(cwd/(label+'.log')).read_text(errors='replace');errors=re.findall(r'^E:.*',text,re.M)
        result['jobs'].append(dict(name=label,exit=child.returncode,errors=errors))
        if child.returncode or errors:raise RuntimeError(label+': '+text[-1500:])
        return text

    try:
        for clients in (1,3,7):
            image=run/('compare_'+str(clients)+'.vvp')
            execute('compile_'+str(clients),[str(tool/'iverilog.exe'),'-g2012','-s','tb_dma_arbiter_differential',
                '-Ptb_dma_arbiter_differential.CLIENTS='+str(clients),'-o',str(image),str(run/'candidate.v'),str(run/'baseline.v'),str(run/fixture.name)],run)
            text=execute('run_'+str(clients),[str(tool/'vvp.exe'),str(image)],run)
            if 'DMA_ARBITER_DIFFERENTIAL_PASS' not in text:raise ValueError('Missing exhaustive PASS')
            print(text.strip(),flush=True)
        for label,path in [('baseline',baseline),('candidate',source)]:
            build=run/label;build.mkdir()
            # The board uses VERIFY_WRITES=1. Change only this probe top's
            # default in both copies; production source remains unchanged.
            text=path.read_text()
            if text.count('parameter VERIFY_WRITES=0')!=1:raise ValueError('Unexpected DMA parameter declaration')
            (build/'dma.v').write_text(text.replace('parameter VERIFY_WRITES=0','parameter VERIFY_WRITES=1',1))
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+build.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow+='add_design {'+(build/'dma.v').as_posix()+'}\nadd_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
            flow+='compile -top_module ddr_native_dma -system_verilog\nsynthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build/'flow.tcl').write_text(flow)
            execute('syn',['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(build/'flow.tcl'),'-work_dir',str(build)],build)
            report=(build/'synthesize/ddr_native_dma.snr').read_text(errors='replace')
            resources={k:int(re.search(p,report)[1]) for k,p in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),('LUTRAM',r'LUTs as dram: (\d+)'),('controlsets',r'Number of unique control sets : (\d+)')]}
            resources['DRM']=float(re.search(r'Total DRM = ([\d.]+)',report)[1])
            result[label+'_resources']=resources;print(label,resources,flush=True)
        result['inputs_intact']=all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in result['inputs'].items())
        if not result['inputs_intact']:raise ValueError('Inputs changed')
        result.update(passed=True,cycle_equivalent=True)
    finally:
        (run/'result.json').write_text(json.dumps(result,indent=2));print('RESULT',run,flush=True)


if __name__=='__main__':main()
