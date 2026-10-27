"""Freeze host codecs and verify compact firmware control compatibility."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    """Test frozen copies; no serial ports, network services or boards opened."""
    host=Path(__file__).resolve().parents[1]
    run=host/'build/pc_only_controls'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    names=['test_algorithm_entities.py','test_fpga_algorithms.py','test_affine_control.py']
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    origins={}
    paths=list((host/'src/pango_video').glob('*.py'))+[host/'tests'/n for n in names]+[host/'web/algorithms.js']
    for p in paths:
        n=p.relative_to(host);target=source/n;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(p,target);origins[n.as_posix()]=sha(p)
    environment=os.environ.copy();environment['PYTHONPATH']=str(source/'src')
    result=dict(passed=False,source=str(source),origins=origins,cases=[],hardware_tested=False)
    try:
        for name in names:
            p=subprocess.run([sys.executable,'-m','unittest','discover','-s',str(source/'tests'),'-p',name],
                             env=environment,cwd=run,capture_output=True,timeout=120)
            (run/(name+'.log')).write_bytes(p.stdout+p.stderr)
            result['cases'].append(dict(test=name,passed=p.returncode==0))
            if p.returncode:raise RuntimeError((p.stdout+p.stderr).decode(errors='replace'))
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(source/n)==h and sha(host/n)==h for n,h in origins.items())
        result['passed'] &= result['inputs_intact']
        report=host/'reports'/('pc_only_controls_'+run.name+'.json')
        report.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('PC_HOST_PROOF',report,flush=True)


if __name__=='__main__':main()
