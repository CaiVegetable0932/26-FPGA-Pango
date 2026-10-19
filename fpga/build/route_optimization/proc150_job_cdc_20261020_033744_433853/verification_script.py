"""Freeze and verify the experimental borrowed-payload job mailbox."""
from datetime import datetime
from pathlib import Path
import hashlib,json,shutil,subprocess

def main():
    fpga=Path(__file__).resolve().parents[1]
    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_job_cdc_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    paths={n:fpga/'experiments/proc150'/d/n for n,d in [
        ('processing_job_cdc.sv','rtl'),('tb_processing_job_cdc.sv','sim')]}
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths.values()}
    for n,p in paths.items():shutil.copyfile(p,run/n)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,production_instantiated=False,timing_signed_off=False,inputs=hashes,tests=[])
    try:
        for sh,ph,phase in [(4,3.333,.7),(3.333,4,1.1),(5,3.1,0),(4,3.333,3.9)]:
            name=f's{sh}_p{ph}_phase{phase}'
            commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-s','processing_job_tb',
                '-Pprocessing_job_tb.SOURCE_HALF='+str(sh),'-Pprocessing_job_tb.PROCESSING_HALF='+str(ph),
                '-Pprocessing_job_tb.PROCESSING_PHASE='+str(phase),'-o',name+'.vvp',*paths]),
                ('run',[str(tool/'vvp.exe'),name+'.vvp'])]
            for stage,cmd in commands:
                p=subprocess.run(cmd,cwd=run,capture_output=True,timeout=120)
                output=p.stdout+p.stderr;(run/(name+'_'+stage+'.log')).write_bytes(output)
                if p.returncode:raise RuntimeError(output.decode(errors='replace'))
            if b'PROCESSING_JOB_CDC_PASS cases=82 accepted=82 completed=82' not in output:
                raise ValueError('Independent scoreboard did not complete')
            result['tests'].append(dict(source_half_ns=sh,processing_half_ns=ph,phase_ns=phase,passed=True,cases=82))
            print(name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in hashes.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2));print('PROCESSING_JOB_CDC_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)

if __name__=='__main__':main()
