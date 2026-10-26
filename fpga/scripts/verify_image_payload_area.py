"""Freeze pixel arithmetic oracles and cycle-exact B3 peers for payload splits."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from regional_scan_wrapper import ports


def sha(path):
    """Bind proofs to their actual immutable RTL and fixture inputs."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Check every output even while invalid, and independent accepted pixels."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    candidate=parser.parse_args().candidate.resolve();fpga=Path(__file__).resolve().parents[1]
    base=Path(json.loads((candidate/'candidate.json').read_text())['baseline'])
    manifest=json.loads((candidate/'sources.json').read_text())
    assert all(sha(candidate/'source'/n)==h for n,h in manifest.items())
    run=candidate/datetime.now().strftime('software_%Y%m%d_%H%M%S_%f');source=run/'source';source.mkdir(parents=True)
    origins={};peer_code=''
    for group,module,instance in [('geometry','rgb_bilinear','bilinear'),('geometry','rgb_enhance','enhance'),('isp','rgb_colour_matrix','colour')]:
        path=candidate/'source/rtl'/group/(module+'.sv');old=base/'source/rtl'/group/path.name
        shutil.copyfile(path,source/path.name);origins[str(path)]=sha(path);origins[str(old)]=sha(old)
        old_text=old.read_text();renamed=re.sub(r'\bmodule '+module+r'\b','module '+module+'_baseline',old_text,count=1)
        if module=='rgb_enhance':renamed=re.sub(r'\brgb_bilinear\b','rgb_bilinear_baseline',renamed)
        (source/(module+'_baseline.sv')).write_text(renamed)
        declared=ports(re.sub(r'\bsigned\s+','',old_text),module,{'TAG_BITS':64})
        peer_code+='\n'+module+'_baseline #(.TAG_BITS(64)) reference_'+instance+'('+','.join('.'+n+'('+instance+'.'+n+')' for d,n,w in declared if d=='input')+');\n'
        peer_code+='always @(posedge clk)begin #0.001;\n'
        for d,n,w in declared:
            if d=='output':peer_code+='if('+instance+'.'+n+' !== reference_'+instance+'.'+n+')$fatal(1,"IMAGE_PAYLOAD_DIFF '+instance+'.'+n+'");\n'
        peer_code+='end\n'
    path=candidate/'source/rtl/geometry/gamma_lut_bank.sv';origins[str(path)]=sha(path);shutil.copyfile(path,source/path.name)
    fixture=fpga/'sim/tb_image_payload_area.sv';origins[str(fixture)]=sha(fixture)
    (source/fixture.name).write_text(fixture.read_text().replace('endmodule',peer_code+'\nendmodule'))
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin';top='tb_image_payload_area'
    commands=[[str(binary/'iverilog.exe'),'-g2012','-s',top,'-o',str(run/(top+'.vvp'))]+[str(p) for p in source.glob('*.sv')],
              [str(binary/'vvp.exe'),str(run/(top+'.vvp'))]]
    result=dict(passed=False,origins=origins,frozen_files=frozen,commands=commands,hardware_tested=False)
    print('IMAGE_PAYLOAD',run,flush=True)
    try:
        for phase,cmd in zip(('compile','run'),commands):
            p=subprocess.run(cmd,input=b'',capture_output=True,timeout=180,cwd=run);out=p.stdout+p.stderr
            (run/(phase+'.log')).write_bytes(out)
            if p.returncode:raise RuntimeError(out.decode(errors='replace')[-3000:])
        result['passed']=b'IMAGE_PAYLOAD_PASS' in out and b'FATAL' not in out
        result['summary']=out.decode(errors='replace');print(result['summary'],flush=True)
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()
