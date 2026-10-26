"""Verify exact geometry arithmetic and accepted-cycle behavior for area work."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from regional_scan_wrapper import ports


def sha(p):
    """Bind arithmetic/overflow evidence to exact source versions."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Retain independent operator oracles and an old/new full-lens comparison."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--candidate',type=Path,required=True)
    a=parser.parse_args();candidate=a.candidate.resolve();fpga=Path(__file__).resolve().parents[1]
    identity=json.loads((candidate/'candidate.json').read_text());base=Path(identity['baseline'])
    hashes=json.loads((candidate/'sources.json').read_text());assert all(sha(candidate/'source'/n)==h for n,h in hashes.items())
    run=candidate/datetime.now().strftime('software_%Y%m%d_%H%M%S_%f');source=run/'source';source.mkdir(parents=True)
    origins={};originals={}
    for group in ('geometry','isp'):
        for p in (candidate/'source/rtl'/group).glob('*.sv'):
            shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    for module in ('signed_mult32_pipe','affine_ray_stepper','lens_inverse_map'):
        p=base/'source/rtl/geometry'/(module+'.sv');origins[str(p)]=sha(p);originals[module]=p.read_text()
        text=re.sub(r'\bmodule '+module+r'\b','module '+module+'_baseline',p.read_text(),count=1)
        if module in ('affine_ray_stepper','lens_inverse_map'):text=re.sub(r'\bsigned_mult32_pipe\b','signed_mult32_pipe_baseline',text)
        (source/(module+'_baseline.sv')).write_text(text)
    tests=['tb_signed_mult32_pipe','tb_lens_overflow','tb_lens_delay_equivalence','tb_step49_area']
    for name in ('tb_algorithm_arithmetic','tb_lens_overflow','tb_lens_delay_equivalence','tb_step49_area'):
        p=fpga/'sim'/(name+'.sv');text=p.read_text();origins[str(p)]=sha(p)
        if name=='tb_step49_area':
            declared=ports(re.sub(r'\bsigned\s+','',originals['affine_ray_stepper']),'affine_ray_stepper',{'TAG_BITS':160})
            code='\n// Compare the complete original public interface on every cycle.\naffine_ray_stepper_baseline reference('+','.join('.'+n+'(dut.'+n+')' for d,n,w in declared if d=='input')+');\n'
            code+='integer diff_cycles=0;always @(posedge clk)begin #0.001;if(rst_n)begin diff_cycles++;\n'
            for d,n,w in declared:
                if d=='output':code+='if(dut.'+n+' !== reference.'+n+')$fatal(1,"STEP49_DIFF '+n+'");\n'
            code+='end end\nfinal $display("STEP49_DIFF_CHECKED cycles=%0d",diff_cycles);\n'
            text=text.replace(' affine_ray_stepper dut(.*);',' affine_ray_stepper dut(.*);'+code)
        (source/p.name).write_text(text)
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,origins=origins,frozen_files=frozen,cases=[],hardware_tested=False)
    print('GEOMETRY_AREA',run,flush=True)
    try:
        for top in tests:
            commands=[[str(binary/'iverilog.exe'),'-g2012','-s',top,'-o',str(run/(top+'.vvp'))]+[str(p) for p in source.glob('*.sv')],
                      [str(binary/'vvp.exe'),str(run/(top+'.vvp'))]]
            entry=dict(test=top,passed=False,commands=commands);result['cases'].append(entry)
            for phase,cmd in zip(['compile','run'],commands):
                p=subprocess.run(cmd,input=b'',capture_output=True,timeout=180,cwd=run);out=p.stdout+p.stderr
                (run/(top+'.'+phase+'.log')).write_bytes(out)
                if p.returncode:raise RuntimeError(out.decode(errors='replace')[-2500:])
            if b'PASS' not in out or b'FATAL' in out:raise RuntimeError('Incomplete geometry proof')
            entry.update(passed=True,summary=out.decode(errors='replace'));print(top,entry['summary'][-400:],flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()
