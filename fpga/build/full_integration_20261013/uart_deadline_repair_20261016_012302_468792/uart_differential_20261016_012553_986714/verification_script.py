"""Compare every public parser output against an independent original instance.

Use firmware golden packet fixtures, low32 clock rollover, and parameterized
deadline-boundary stress. Both implementations keep separate RAM/control state.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Freeze inputs, build the dual implementation, then compare each cycle."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):raise ValueError('Frozen FPGA candidate required')
    run=candidate/datetime.now().strftime('uart_differential_%Y%m%d_%H%M%S_%f');run.mkdir()
    inputs={}
    def bound(p):
        inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest();return p.read_text()
    current=bound(candidate/'source/rtl/control/uart_v2_parser.sv');old=bound(candidate/'original_uart_v2_parser.sv')
    marker='module uart_v2_parser #(';start=current.index(marker)
    header=current[start:current.index(' localparam FETCH=',start)].replace('output reg ','output wire ')
    outputs=dict(packet_valid='',cmd='[7:0]',seq='[15:0]',length='[15:0]',receive_us='[63:0]',read_response='',read_data='[7:0]',bad_crc='[31:0]',bad_header='[31:0]',timeouts='[31:0]',overflows='[31:0]',peak_bytes='[11:0]')
    ins='clk rst_n now_us byte_valid byte_data byte_error packet_ready read_valid read_index'.split()
    body='\n // Reference and candidate have independent byte/time memories.\n'
    body+='\n'.join(' wire '+w+' ref_'+n+';' for n,w in outputs.items())+'\n'
    for label,kind,prefix in [('candidate_impl','uart_parser_candidate',''),('reference_impl','uart_parser_reference','ref_')]:
        ports=['.'+n+'('+n+')' for n in ins]+['.'+n+'('+prefix+n+')' for n in outputs]
        body+=' '+kind+' #(.TIMEOUT_US(TIMEOUT_US),.WIRE_VERSION(WIRE_VERSION)) '+label+'('+','.join(ports)+');\n'
    body+=' integer compared_cycles=0;\n always @(negedge clk)begin #1;if(rst_n)begin\n compared_cycles=compared_cycles+1;\n'
    for n in outputs:body+=' if('+n+' !== ref_'+n+')$fatal(1,"UART_DEADLINE_DIFFERENTIAL '+n+'");\n'
    body+=' end end\n final begin if(compared_cycles<100)$fatal(1,"insufficient parser coverage");$display("UART_DEADLINE_DIFFERENTIAL_PASS cycles=%0d",compared_cycles);end\nendmodule\n'
    # The wrapper contains delayed observations; explicitly retain the fixture's
    # nanosecond time unit so comparisons execute before simulation finishes.
    (run/'dual_parser.sv').write_text('`timescale 1ns/1ps\n'+header+body+current.replace(marker,'module uart_parser_candidate #(',1)+'\n'+old.replace(marker,'module uart_parser_reference #(',1))
    base=bound(fpga/'sim/tb_uart_v2_parser.sv')
    (run/'tb_original.sv').write_text(base)
    # Shift the same golden regression across low32 rollover, preserving every
    # assertion and byte interval, including absolute timeout and overflow.
    if base.count('now_us=0;')!=1:raise ValueError('Unexpected golden fixture')
    (run/'tb_rollover.sv').write_text(base.replace('now_us=0;',"now_us=64'h00000007fffffff0;",1))
    stress=fpga/'sim/tb_uart_deadline_stress.sv';bound(stress);shutil.copyfile(stress,run/stress.name)
    for name in ('state.hex','nested_bad_crc.hex','bad_length_then_state.hex','bad_version_then_state.hex','payload_magic.hex'):
        p=fpga/'sim/vectors/network_control'/name;bound(p);shutil.copyfile(p,run/name)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,cycle_equivalent=False,inputs=inputs,tests=[],scope='All public parser outputs each active cycle, independent firmware vectors and parameter/boundary stress; no full-board timing claim')
    cases=[('golden','tb_uart_v2_parser','tb_original.sv',None,42),('rollover_golden','tb_uart_v2_parser','tb_rollover.sv',None,42)]
    for value in ('0','1','30000',"32'h7fffffff","32'h80000000","32'hffffffff",'-1',"64'h100000000"):
        cases.append(('boundary_'+str(len(cases)),'tb_uart_deadline_stress',stress.name,value,177))
    try:
        for label,top,fixture,value,seed in cases:
            image=run/(label+'.vvp');cmd=[str(tool/'iverilog.exe'),'-g2012','-s',top,'-o',str(image)]
            if value is not None:cmd+=['-P'+top+'.TIMEOUT_VALUE='+value]
            cmd+=[str(run/'dual_parser.sv'),str(run/fixture)]
            for phase,command in [('compile',cmd),('run',[str(tool/'vvp.exe'),str(image),'+seed='+str(seed)])]:
                proc=subprocess.run(command,cwd=run,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
                (run/(label+'.'+phase+'.log')).write_bytes(proc.stdout);log=proc.stdout.decode(errors='replace')
                expected='UART_V2_PARSER_PASS' if value is None else 'UART_DEADLINE_STRESS_PASS'
                if proc.returncode or 'FATAL' in log or (phase=='run' and (expected not in log or 'UART_DEADLINE_DIFFERENTIAL_PASS' not in log)):
                    raise RuntimeError(label+' '+phase+': '+log[-5000:])
            result['tests'].append(dict(name=label,timeout_override=value,seed=seed));print(label,'PASS',flush=True)
        result.update(passed=True,cycle_equivalent=True)
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed']=result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('RUN',run,flush=True)


if __name__=='__main__':
    main()
