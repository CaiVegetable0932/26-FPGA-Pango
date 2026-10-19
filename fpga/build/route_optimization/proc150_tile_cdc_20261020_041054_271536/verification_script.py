"""Verify the bounded quad-stream bridge with independent producer/consumer."""
from pathlib import Path
from datetime import datetime
import hashlib,json,re,shutil,subprocess

def main():
    f=Path(__file__).resolve().parents[1]
    run=f/'build/route_optimization'/datetime.now().strftime('proc150_tile_cdc_%Y%m%d_%H%M%S_%f');run.mkdir()
    files={'tile_refill_cdc.sv':f/'experiments/proc150/rtl/tile_refill_cdc.sv',
        'tb_tile_refill_cdc.sv':f/'experiments/proc150/sim/tb_tile_refill_cdc.sv',
        'async_stream_fifo.sv':f/'rtl/memory/async_stream_fifo.sv'}
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files.values()}
    for n,p in files.items():shutil.copyfile(p,run/n)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=f/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,production_instantiated=False,independent_quad_and_metadata_scoreboard=True,inputs=hashes,tests=[])
    try:
        for ph,mh,phase in [(3.333,4,.7),(4,3.333,1.1),(5,3.1,0),(3.333,4,3.9)]:
            for always in [0,1]:
                name=f'p{ph}_m{mh}_phase{phase}_ready{always}'
                cmds=[('compile',[str(tool/'iverilog.exe'),'-g2012','-s','tile_cdc_tb',
                    '-Ptile_cdc_tb.PROC_HALF='+str(ph),'-Ptile_cdc_tb.MEM_HALF='+str(mh),
                    '-Ptile_cdc_tb.MEM_PHASE='+str(phase),'-Ptile_cdc_tb.ALWAYS_READY='+str(always),
                    '-o',name+'.vvp',*files]),('run',[str(tool/'vvp.exe'),name+'.vvp'])]
                for stage,cmd in cmds:
                    p=subprocess.run(cmd,cwd=run,capture_output=True,timeout=120);output=p.stdout+p.stderr
                    (run/(name+'_'+stage+'.log')).write_bytes(output)
                    if p.returncode:raise RuntimeError(output.decode(errors='replace'))
                marker=re.search(rb'TILE_REFILL_CDC_PASS cases=(\d+) quads=(\d+) stalls=(\d+)',output)
                if not marker:raise ValueError('Missing independent scoreboard')
                result['tests'].append(dict(processing_half_ns=ph,memory_half_ns=mh,phase_ns=phase,always_ready=always,
                    cases=int(marker[1]),quads=int(marker[2]),stalls=int(marker[3])))
                print(name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in hashes.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2));print('TILE_REFILL_CDC_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)

if __name__=='__main__':main()
