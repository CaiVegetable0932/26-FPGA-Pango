"""Compare independent original/candidate DMA banks under the same traffic.

Keep native-memory scoreboards, seven-client arbitration, cancellation/fault
tests and the real frame fabric's full write-readback verification. Compare
every control/statistics output, active native write/readback and client data.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Build a simulation-only dual implementation wrapper from frozen RTL."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--regression-fixtures',type=Path,
                        help='Use already-passing frozen integration fixtures for latency-aware ownership')
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):
        raise ValueError('Candidate must be under fpga/build')
    fixture_root=fpga/'sim'
    if args.regression_fixtures:
        regression=args.regression_fixtures.resolve()
        if not regression.is_relative_to(fpga/'build') or not json.loads((regression/'result.json').read_text()).get('passed'):
            raise ValueError('Passing frozen regression required for adapted fixtures')
        fixture_root=regression/'source'
    run=candidate/datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f');run.mkdir()
    inputs={}
    source=candidate/'source/rtl/memory/ddr_native_dma.v'
    original=candidate/'original_ddr_native_dma.v'
    for p in (source,original):inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
    current=source.read_text(encoding='utf-8')
    previous=original.read_text(encoding='utf-8')
    start=current.index('module ddr_native_dma #(')
    header=current[start:current.index('\n localparam',start)].replace('output reg ','output wire ')
    outputs={n:'[CLIENTS-1:0]' for n in 'req_ready w_ready r_valid r_last done cancelled error write_verified'.split()}
    outputs.update(r_data='[CLIENTS*256-1:0]',done_tag='[CLIENTS*TAG_BITS-1:0]',
        max_wait_cycles='[CLIENTS*32-1:0]',bus_bytes='[CLIENTS*32-1:0]',useful_write_bytes='[CLIENTS*32-1:0]',
        awaddr='[27:0]',araddr='[27:0]',awlen='[3:0]',awid='[3:0]',arlen='[3:0]',arid='[3:0]',
        awvalid='',arvalid='',native_wdata='[255:0]',native_wstrb='[31:0]',fault='')
    ins='clk rst_n controller_ready allow_snapshot req_valid req_write req_addr req_beats req_tag urgent cancel w_valid w_data w_strb r_ready done_ready awready native_wready native_wid native_wlast arready native_rdata native_rvalid native_rid native_rlast'.split()
    params='CLIENTS TAG_BITS MAX_BEATS EMERGENCY_QUOTA VERIFY_WRITES CAPACITY_BYTES'.split()
    parameter_ports='#('+','.join('.'+n+'('+n+')' for n in params)+')'
    body='\n'.join(' wire '+width+' ref_'+n+';' for n,width in outputs.items())+'\n'
    for label,typename,prefix in [('candidate_impl','ddr_native_dma_candidate',''),('reference_impl','ddr_native_dma_baseline','ref_')]:
        ports=['.'+n+'('+n+')' for n in ins]+['.'+n+'('+prefix+n+')' for n in outputs]
        body+=' '+typename+' '+parameter_ports+' '+label+'('+','.join(ports)+');\n'
    common=[n for n in outputs if n not in ('r_data','native_wdata')]
    body+=''' // Preserve the fixture's two read-only observations; they do not drive
 // either implementation or share storage/control state between the instances.
 wire [CLIENTS-1:0] returned=candidate_impl.returned;
 wire [2:0] state=candidate_impl.state;
 integer lane,compared_cycles=0;
 always @(negedge clk)begin #1;
  if(rst_n)begin
   compared_cycles=compared_cycles+1;
'''
    body+='   if({'+','.join(common)+'} !== {'+','.join('ref_'+n for n in common)+'})$fatal(1,"DMA_DIFFERENTIAL control/statistics");\n'
    body+='''   for(lane=0;lane<CLIENTS;lane=lane+1)
    if(r_valid[lane] && r_data[lane*256+:256] !== ref_r_data[lane*256+:256])
     $fatal(1,"DMA_DIFFERENTIAL client read data");
   // Write payload is observable from WA through WD, and throughout full
   // verification readback. Only the inactive IDLE write-bank cursor differs.
   if((state==1 || state==2 || state==5 || state==6) && native_wdata !== ref_native_wdata)
    $fatal(1,"DMA_DIFFERENTIAL native write/readback data");
  end
 end
endmodule
'''
    (run/'ddr_native_dma.v').write_text('`timescale 1ns/1ps\n'+header+body+'\n'+
        current.replace('module ddr_native_dma #(','module ddr_native_dma_candidate #(',1)+'\n'+
        previous.replace('module ddr_native_dma #(','module ddr_native_dma_baseline #(',1),encoding='utf-8')
    names=['rtl/memory/frame_manager_pkg.sv','rtl/memory/frame_manager_layout.vh',
        'rtl/memory/frame_pool_bank.sv','rtl/memory/frame_manager.sv','rtl/memory/frame_memory_fabric.sv',
        'sim/tb_ddr_native_dma.sv','sim/tb_frame_memory_fabric.sv']
    for name in names:
        # Reuse the exact bounded-wait fixture already checked against this
        # control interface; every input byte remains part of the proof hash.
        p=(candidate/'source'/name) if name.startswith('rtl/') else fixture_root/Path(name).name
        inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
        shutil.copyfile(p,run/p.name)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,cycle_equivalent=False,inputs=inputs,tests=[])
    result['scope']='DMA original versus prefetch candidate; common frame-bank implementation is not claimed cycle-equivalent to its older version'
    sources=[str(run/Path(n).name) for n in names if not n.endswith('.vh')]
    sources.append(str(run/'ddr_native_dma.v'))
    try:
        cases=[('transport_'+str(cap)+'_'+str(seed),'tb_ddr_native_dma',cap,seed)
               for cap in (4,8,16) for seed in (42,177,2718)]
        cases.append(('full_readback','tb_frame_memory_fabric',16,42))
        for label,top,cap,seed in cases:
            image=run/(label+'.vvp')
            cmd=[str(tool/'iverilog.exe'),'-g2012','-I',str(run),'-s',top,'-o',str(image)]
            if top=='tb_ddr_native_dma':cmd+=['-P'+top+'.BURST_CAP='+str(cap)]
            for phase,command in [('compile',cmd+sources),('run',[str(tool/'vvp.exe'),str(image),'+seed='+str(seed)])]:
                proc=subprocess.run(command,cwd=run,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
                (run/(label+'.'+phase+'.log')).write_bytes(proc.stdout)
                log=proc.stdout.decode(errors='replace')
                if proc.returncode or (phase=='run' and '_PASS' not in log):
                    raise RuntimeError(label+' '+phase+': '+log[-4000:])
            result['tests'].append(label);print(label,'PASS',flush=True)
        result['inputs_intact']=all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in inputs.items())
        if not result['inputs_intact']:raise ValueError('Inputs changed')
        result.update(passed=True,cycle_equivalent=True)
    finally:
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print('RUN',run,flush=True)


if __name__=='__main__':
    main()
