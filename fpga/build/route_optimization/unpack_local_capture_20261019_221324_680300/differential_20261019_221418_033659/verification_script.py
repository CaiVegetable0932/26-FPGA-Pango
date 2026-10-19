"""Prove unchanged unpack outputs on both parameter branches before synthesis."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Retain sources, logs, coverage and hashes for six strict differential runs."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();candidate=args.candidate.resolve()
    fpga=Path(__file__).resolve().parents[1]
    if not candidate.is_relative_to(fpga/'build/route_optimization'):
        raise ValueError('Frozen unpack candidate required')
    original=candidate/'original_dma_byte_unpack.v'
    changed=candidate/'source/rtl/memory/dma_byte_unpack.v'
    fixture=fpga/'sim/tb_unpack_local_capture_equivalence.sv'
    inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (original,changed,fixture)}
    run=candidate/datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(__file__,run/'verification_script.py')
    shutil.copyfile(changed,run/changed.name);shutil.copyfile(fixture,run/fixture.name)
    reference=original.read_text(encoding='utf-8')
    if reference.count('module dma_byte_unpack ')!=1:
        raise ValueError('Unexpected original unpack module')
    (run/'reference.v').write_text(reference.replace('module dma_byte_unpack ',
        'module dma_byte_unpack_reference ',1),encoding='utf-8')
    runtime=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,cycle_equivalent=False,inputs=inputs,tests=[])
    try:
        for aligned in (0,1):
            image=run/f'unpack_{aligned}.vvp'
            command=[str(runtime/'iverilog.exe'),'-g2012','-s','tb_unpack_local_capture_equivalence',
                '-Ptb_unpack_local_capture_equivalence.ALIGNED_ROWS='+str(aligned),'-o',str(image),
                str(run/'reference.v'),str(run/changed.name),str(run/fixture.name)]
            with (run/f'compile_{aligned}.log').open('wb') as log:
                compiled=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=60)
            if compiled.returncode: raise RuntimeError('Unpack differential compile failed')
            for seed in (42,177,2718):
                log_path=run/f'aligned_{aligned}_seed_{seed}.log'
                with log_path.open('wb') as log:
                    completed=subprocess.run([str(runtime/'vvp.exe'),str(image),f'+seed={seed}'],
                        stdout=log,stderr=subprocess.STDOUT,timeout=120)
                text=log_path.read_text(errors='replace')
                if completed.returncode or 'UNPACK_LOCAL_CAPTURE_PASS' not in text:
                    raise RuntimeError('Unpack differential failure: '+str(log_path))
                result['tests'].append(dict(aligned_rows=aligned,seed=seed,checks=50000))
                print(text.splitlines()[0],flush=True)
        result.update(passed=True,cycle_equivalent=True)
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed']=result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print('UNPACK_PROOF',run,flush=True)


if __name__=='__main__':main()
