"""Freeze and verify the streaming CCM proof and compatible default modules."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def sha(p):
    """Record the exact files tested, including original comparison modules."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Compare end-to-end legality, then run existing image/boot scoreboards."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--candidate',type=Path,required=True)
    a=parser.parse_args();candidate=a.candidate.resolve();fpga=Path(__file__).resolve().parents[1]
    identity=json.loads((candidate/'candidate.json').read_text());baseline=Path(identity['baseline'])
    hashes=json.loads((candidate/'sources.json').read_text());assert all(sha(candidate/'source'/n)==h for n,h in hashes.items())
    run=candidate/datetime.now().strftime('software_%Y%m%d_%H%M%S_%f');source=run/'source';source.mkdir(parents=True)
    origins={}
    for group in ['control','geometry','memory','isp','input']:
        for p in (candidate/'source/rtl'/group).iterdir():
            if p.suffix in ('.sv','.v','.vh'):
                assert not (source/p.name).exists();shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    for n in ['control/pc_reference_upload.sv','isp/isp_colour_control.sv']:
        p=baseline/'source/rtl'/n;module=p.stem;origins[str(p)]=sha(p)
        (source/(module+'_baseline.sv')).write_text(re.sub(r'\bmodule '+module+r'\b','module '+module+'_baseline',p.read_text(),count=1))
    tests=['tb_stream_ccm_upload','tb_pc_video_boot','tb_image_entities','tb_image_manual_profile','tb_isp_colour_entity','tb_pc_tone_gateway']
    for name in ['tb_stream_ccm_upload','tb_pc_video_boot','tb_image_entities','tb_image_manual_profile','tb_pc_tone_gateway']:
        p=fpga/'sim'/(name+'.sv');shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    for p in (fpga/'sim/vectors/network_control').glob('*.hex'):
        shutil.copyfile(p,run/p.name);origins[str(p)]=sha(p)
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    sources=sorted([p for p in source.iterdir() if p.suffix in ('.v','.sv')],key=lambda p:0 if p.name=='frame_manager_pkg.sv' else 1)
    result=dict(passed=False,origins=origins,frozen_files=frozen,cases=[],hardware_tested=False)
    print('STREAM_CCM',run,flush=True)
    try:
        for top in tests:
            commands=[[str(binary/'iverilog.exe'),'-g2012','-I',str(source),'-s',top,'-o',str(run/(top+'.vvp'))]+list(map(str,sources)),
                      [str(binary/'vvp.exe'),str(run/(top+'.vvp'))]]
            entry=dict(test=top,passed=False,commands=commands);result['cases'].append(entry)
            for phase,cmd in zip(['compile','run'],commands):
                p=subprocess.run(cmd,input=b'',capture_output=True,timeout=180,cwd=run);out=p.stdout+p.stderr
                (run/(top+'.'+phase+'.log')).write_bytes(out)
                if p.returncode:raise RuntimeError(out.decode(errors='replace')[-3000:])
            if b'PASS' not in out or b'FATAL' in out:raise RuntimeError('Incomplete scoreboard')
            entry.update(passed=True,summary=out.decode(errors='replace'));print(top,entry['summary'][-400:],flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()
