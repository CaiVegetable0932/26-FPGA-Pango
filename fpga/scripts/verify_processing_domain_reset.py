"""Verify common cold reset, startup ordering and stopped-clock assertion."""
from pathlib import Path
from datetime import datetime
import hashlib,json,shutil,subprocess

def main():
    f=Path(__file__).resolve().parents[1]
    run=f/'build/route_optimization'/datetime.now().strftime('proc150_reset_%Y%m%d_%H%M%S_%f');run.mkdir()
    inputs={'processing_domain_reset.sv':f/'experiments/proc150/rtl/processing_domain_reset.sv',
        'tb_processing_domain_reset.sv':f/'experiments/proc150/sim/tb_processing_domain_reset.sv','reset_sync.v':f/'rtl/board/reset_sync.v'}
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs.values()}
    for n,p in inputs.items():shutil.copyfile(p,run/n)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=f/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,production_instantiated=False,native_controller_is_behavioral_model=True,inputs=hashes)
    try:
        for stage,cmd in [('compile',[str(tool/'iverilog.exe'),'-g2012','-s','processing_reset_tb','-o','test.vvp',*inputs]),
                          ('run',[str(tool/'vvp.exe'),'test.vvp'])]:
            p=subprocess.run(cmd,cwd=run,capture_output=True,timeout=60);output=p.stdout+p.stderr
            (run/(stage+'.log')).write_bytes(output)
            if p.returncode:raise RuntimeError(output.decode(errors='replace'))
        result['passed']=b'PROCESSING_RESET_PASS cases=7' in output
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in hashes.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
        print('PROCESSING_RESET_PROOF',run,'passed',result['passed'],flush=True)
    if not result['passed']:raise SystemExit(1)

if __name__=='__main__':main()
