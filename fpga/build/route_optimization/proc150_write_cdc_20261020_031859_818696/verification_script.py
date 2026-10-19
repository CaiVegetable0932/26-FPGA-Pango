"""Exercise the unintegrated write CDC prototype with an independent backend."""
from datetime import datetime
import hashlib,json,re,shutil,subprocess
from pathlib import Path


def main():
    fpga=Path(__file__).resolve().parents[1]
    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_write_cdc_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    paths={'dma_write_cdc.sv':fpga/'experiments/proc150/rtl/dma_write_cdc.sv',
           'tb_dma_write_cdc.sv':fpga/'experiments/proc150/sim/tb_dma_write_cdc.sv'}
    inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths.values()}
    for n,p in paths.items():shutil.copyfile(p,run/n)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,experimental=True,production_instantiated=False,hardware_tested=False,
        timing_signed_off=False,cdc_constraints_signed_off=False,inputs=inputs,tests=[])
    try:
        for ch,mh,phase in [(3.333,4.0,.7),(4.0,3.333,1.1),(5.0,3.1,0.0),(3.333,4.0,3.9)]:
            name=f'c{ch}_m{mh}_p{phase}'
            commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-s','write_cdc_tb',
                '-Pwrite_cdc_tb.CLIENT_HALF='+str(ch),'-Pwrite_cdc_tb.MEMORY_HALF='+str(mh),
                '-Pwrite_cdc_tb.MEMORY_PHASE='+str(phase),'-o',name+'.vvp',*paths]),
                ('run',[str(tool/'vvp.exe'),name+'.vvp'])]
            for stage,command in commands:
                p=subprocess.run(command,cwd=run,capture_output=True,timeout=120)
                output=p.stdout+p.stderr;(run/(name+'_'+stage+'.log')).write_bytes(output)
                if p.returncode:raise RuntimeError(name+' '+stage+': '+output.decode(errors='replace')[-2000:])
            marker=re.search(rb'WRITE_CDC_PASS cases=(\d+) requests=(\d+) beats=(\d+) errors=(\d+) cancels=(\d+) stalls=(\d+)',output)
            if not marker:raise ValueError('Independent backend did not complete')
            result['tests'].append(dict(client_half_ns=ch,memory_half_ns=mh,phase_ns=phase,
                counts=dict(zip(['cases','requests','beats','errors','cancels','stalls'],map(int,marker.groups())))))
            print(name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
        print('PROC150_WRITE_CDC_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()
