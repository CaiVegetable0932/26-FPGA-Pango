"""Check pose work-register ownership and bounded admitted arithmetic."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def sha(p):
    """Bind every claim to its frozen model, independent fixture and source."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Exercise full signed input limits, clear, warm reset and held results."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--candidate',type=Path,required=True)
    a=parser.parse_args();candidate=a.candidate.resolve();fpga=Path(__file__).resolve().parents[1]
    base=Path(json.loads((candidate/'candidate.json').read_text())['baseline'])
    hashes=json.loads((candidate/'sources.json').read_text());assert all(sha(candidate/'source'/n)==h for n,h in hashes.items())
    run=candidate/datetime.now().strftime('software_%Y%m%d_%H%M%S_%f');source=run/'source';source.mkdir(parents=True)
    origins={}
    for name in ('pose_affine_model.sv','pose_frame_selector.sv','affine_dynamic_compose.sv'):
        p=candidate/'source/rtl/control'/name
        if not p.exists():p=candidate/'source/rtl/stabilization'/name
        shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    old=base/'source/rtl/control/pose_affine_model.sv';origins[str(old)]=sha(old)
    (source/'pose_affine_model_before.sv').write_text(re.sub(r'\bmodule pose_affine_model\b','module pose_affine_model_before',old.read_text(),count=1))
    for top in ('tb_pose_storage_equivalence','tb_encoder_pose_model','tb_motion_algorithms'):
        p=fpga/'sim'/(top+'.sv');origins[str(p)]=sha(p);text=p.read_text()
        if top=='tb_pose_storage_equivalence':
            text=text.replace('pose_affine_model_before reference_model','pose_affine_model_before #(.CALIBRATION_PREVALIDATED(PREVALIDATED)) reference_model')
            text=text.replace('trial<256','trial<1024').replace('256 requests','1024 requests')
            text=text.replace('   endcase\n  end\n endtask', '''   endcase
   // Full signed32 centers/angles exercise the signed33 admission check;
   // only accepted differences, never the public angles, may be narrowed.
   if(trial%32>=16 && trial%32<=19)begin
    calibration[128+:32]=32'h80000000;calibration[160+:32]=32'h7fffffff;
    pose[416+:32]=trial%32==17?32'h80000000:32'h7fffffff;
    case(trial%32)
     16:calibration[64+:32]=32'h7fffffff-90000;
     17:calibration[64+:32]=32'h80000000+90000;
     18:calibration[64+:32]=32'h80000000;
     19:calibration[64+:32]=32'h7fffffff-90001;
    endcase
   end
  end
 endtask''')
            text=text.replace('   if(trial%16==15)begin', '''   if(trial%32==30)begin
    // Revoke a pending computation before its work banks have fully shifted.
    repeat(4)@(negedge clk);rst_n=0;repeat(2)@(negedge clk);rst_n=1;result_ready=1;
   end else if(trial%16==15)begin''')
        (source/p.name).write_text(text)
    data=source/'sim/data';data.mkdir(parents=True)
    for name in ('state_encoder.hex','state_stale.hex'):
        p=fpga/'sim/data'/name;shutil.copyfile(p,data/name);origins[str(p)]=sha(p)
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    cases=[('tb_pose_storage_equivalence',{'PREVALIDATED':n}) for n in (0,1)]+[('tb_encoder_pose_model',{}),('tb_motion_algorithms',{})]
    result=dict(passed=False,origins=origins,frozen_files=frozen,cases=[],hardware_tested=False)
    print('POSE_PAYLOAD',run,flush=True)
    try:
        for top,params in cases:
            label=top+('_'+str(params['PREVALIDATED']) if params else '')
            commands=[[str(binary/'iverilog.exe'),'-g2012','-s',top,'-o',str(run/(label+'.vvp'))]+
                      ['-P'+top+'.'+n+'='+str(v) for n,v in params.items()]+[str(p) for p in source.glob('*.sv')],
                      [str(binary/'vvp.exe'),str(run/(label+'.vvp'))]]
            entry=dict(test=top,parameters=params,passed=False,commands=commands);result['cases'].append(entry)
            for phase,cmd in zip(('compile','run'),commands):
                p=subprocess.run(cmd,input=b'',capture_output=True,timeout=180,cwd=run);out=p.stdout+p.stderr
                (run/(label+'.'+phase+'.log')).write_bytes(out)
                if p.returncode:raise RuntimeError(out.decode(errors='replace')[-3000:])
            if b'PASS' not in out or b'FATAL' in out:raise RuntimeError('Incomplete pose proof')
            entry.update(passed=True,summary=out.decode(errors='replace'));print(label,entry['summary'][-400:],flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()
