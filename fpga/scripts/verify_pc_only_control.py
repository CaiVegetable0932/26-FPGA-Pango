"""Freeze and exercise PC control compatibility plus compact readback."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Retain every oracle log and source hash; never launch PDS here."""
    fpga=Path(__file__).resolve().parents[1]
    run=fpga/'build/pc_only_20261026'/datetime.now().strftime('proof_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    origins={}
    for group in ['control','geometry','memory','isp','input','stabilization']:
        for p in (fpga/'rtl'/group).iterdir():
            if p.suffix in ('.sv','.v','.vh'):
                shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    cases=['tb_pc_video_boot','tb_pc_runtime_control','tb_pc_reference_upload','tb_pc_summary_readback',
           'tb_pc_tone_gateway','tb_pc_camera_validation','tb_image_manual_profile']
    for top in cases:
        p=fpga/'sim'/(top+'.sv');shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    # Repeat the real UART geometry/reference/affine/CRC/retry scenario using
    # the production compact gateway. The trailing LUT/history tests belong
    # to the retained legacy default and are covered by the original fixture.
    runtime=(source/'tb_pc_runtime_control.sv').read_text()
    runtime=runtime.replace('module tb_pc_runtime_control;', 'module tb_pc_only_runtime;')
    runtime=runtime.replace(".ENTITY_MASK(16'h0bee)",".ENTITY_MASK(16'h028a),.SUMMARY_READBACK(1),.STREAM_CCM(1)")
    runtime=runtime.replace("response[798+24]!=8'hee || response[798+25]!=8'h0f", "response[798+24]!=8'h8a || response[798+25]!=8'h06")
    runtime=runtime.split('  // A full 12-page LUT record',1)[0]+'''
  // All forty retained dynamic-control responses must have valid wire CRC.
  for(p=0;p<40;p=p+1)begin
   crc=16'hffff;for(i=2;i<40;i=i+1)crc=crc_byte(crc,response[p*42+i]);
   if({response[p*42+41],response[p*42+40]}!=crc)$fatal(1,"compact runtime CRC");
  end
  $display("PC_ONLY_RUNTIME_PASS 40 serial replies geometry reference affine ON OFF retries");$finish;
 end
 initial begin #5000000;$fatal(1,"compact runtime timeout");end
endmodule
'''
    (source/'tb_pc_only_runtime.sv').write_text(runtime)
    cases.append('tb_pc_only_runtime')
    for p in (fpga/'sim/vectors/network_control').glob('*.hex'):shutil.copyfile(p,run/p.name)
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    files=sorted([p for p in source.iterdir() if p.suffix in ('.sv','.v')],key=lambda p:0 if p.name=='frame_manager_pkg.sv' else 1)
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    result=dict(passed=False,origins=origins,frozen=frozen,cases=[],hardware_tested=False)
    print('PC_ONLY_PROOF',run,flush=True)
    try:
        for top in cases:
            commands=[[str(binary/'iverilog.exe'),'-g2012','-I',str(source),'-s',top,'-o',str(run/(top+'.vvp'))]+list(map(str,files)),
                      [str(binary/'vvp.exe'),str(run/(top+'.vvp'))]]
            for phase,cmd in zip(['compile','run'],commands):
                p=subprocess.run(cmd,cwd=run,capture_output=True,timeout=180)
                output=p.stdout+p.stderr;(run/(top+'.'+phase+'.log')).write_bytes(output)
                if p.returncode:raise RuntimeError(output.decode(errors='replace')[-2500:])
            assert b'PASS' in output and b'FATAL' not in output
            result['cases'].append(dict(test=top,passed=True));print(top,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')


if __name__=='__main__':main()
